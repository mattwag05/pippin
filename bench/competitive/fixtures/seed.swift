// pb-seed: seeds, dumps and removes the PippinBench calendar, reminders list and contacts.
// Independent of every tool under test: EventKit and Contacts only.
// Run ONLY inside the disposable benchmark VM.
//
//   pb-seed seed <manifest.json>      create everything (after removing prior PippinBench containers); prints state JSON
//   pb-seed dump                      print what is in the stores now, as JSON
//   pb-seed teardown <state.json>     remove exactly the listed identifiers and verify they are gone
//   pb-seed typedstream               stdin: JSON array of strings; stdout: JSON array of hex NSArchiver blobs
//   pb-seed untypedstream             stdin: JSON array of hex blobs; stdout: JSON array of strings
import Contacts
import EventKit
import Foundation

let marker = "PippinBench"
let familyPrefix = "PBX"
let dueZone = TimeZone(identifier: "America/New_York")!

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("pb-seed: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadJSON(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail("cannot read JSON at \(path)") }
    return obj
}

func emit(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func parseISO(_ s: String) -> Date {
    guard let d = ISO8601DateFormatter().date(from: s) else { fail("bad date \(s)") }
    return d
}

func dayFormatter() -> DateFormatter {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current  // all-day events are floating: they sit on the local calendar day
    f.dateFormat = "yyyy-MM-dd"
    return f
}

func nonEmpty(_ v: Any?) -> String? {
    guard let s = v as? String, !s.isEmpty else { return nil }
    return s
}

// ---------------------------------------------------------------- access
final class Flag: @unchecked Sendable { var value = false }

func requireAccess() -> (EKEventStore, CNContactStore) {
    let store = EKEventStore()
    let contacts = CNContactStore()
    let sem = DispatchSemaphore(value: 0)
    let ev = Flag(), rem = Flag(), con = Flag()
    store.requestFullAccessToEvents { granted, _ in ev.value = granted; sem.signal() }
    sem.wait()
    store.requestFullAccessToReminders { granted, _ in rem.value = granted; sem.signal() }
    sem.wait()
    contacts.requestAccess(for: .contacts) { granted, _ in con.value = granted; sem.signal() }
    sem.wait()
    if !(ev.value && rem.value && con.value) {
        fail("access denied (calendar=\(ev.value) reminders=\(rem.value) contacts=\(con.value)); run: sh ~/grant.sh \(CommandLine.arguments[0])")
    }
    return (store, contacts)
}

// ---------------------------------------------------------------- lookups
func markerCalendars(_ store: EKEventStore, _ type: EKEntityType) -> [EKCalendar] {
    store.calendars(for: type).filter { $0.title == marker }
}

func source(_ store: EKEventStore, _ type: EKEntityType) -> EKSource {
    if let s = store.sources.first(where: { $0.sourceType == .local }) { return s }
    let fallback = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
    guard let s = fallback?.source else { fail("no calendar source available") }
    return s
}

let contactKeys: [CNKeyDescriptor] = [
    CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
    CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
].map { $0 as CNKeyDescriptor }

func prefixedContacts(_ contacts: CNContactStore) -> [CNContact] {
    var out: [CNContact] = []
    let request = CNContactFetchRequest(keysToFetch: contactKeys)
    request.unifyResults = false
    try! contacts.enumerateContacts(with: request) { c, _ in
        if c.familyName.hasPrefix(familyPrefix) { out.append(c) }
    }
    return out
}

func markerGroups(_ contacts: CNContactStore) -> [CNGroup] {
    ((try? contacts.groups(matching: nil)) ?? []).filter { $0.name == marker }
}

func fetchReminders(_ store: EKEventStore, _ cals: [EKCalendar]) -> [EKReminder] {
    if cals.isEmpty { return [] }
    let sem = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var items: [EKReminder] = [] }
    let box = Box()
    store.fetchReminders(matching: store.predicateForReminders(in: cals)) { found in
        box.items = found ?? []
        sem.signal()
    }
    sem.wait()
    return box.items
}

// ---------------------------------------------------------------- seed
func removePrior(_ store: EKEventStore, _ contacts: CNContactStore) throws {
    for cal in markerCalendars(store, .event) + markerCalendars(store, .reminder) {
        try store.removeCalendar(cal, commit: true)
    }
    let request = CNSaveRequest()
    for c in prefixedContacts(contacts) { request.delete(c.mutableCopy() as! CNMutableContact) }
    for g in markerGroups(contacts) { request.delete(g.mutableCopy() as! CNMutableGroup) }
    try contacts.execute(request)
}

func seed(_ manifestPath: String) throws {
    let manifest = loadJSON(manifestPath)
    let (store, contacts) = requireAccess()
    try removePrior(store, contacts)
    var state: [String: Any] = [:]

    // calendar and events
    let cal = EKCalendar(for: .event, eventStore: store)
    cal.title = marker
    cal.source = source(store, .event)
    try store.saveCalendar(cal, commit: true)
    var created: [(String, EKEvent)] = []
    let events = (manifest["calendar"] as! [String: Any])["events"] as! [[String: Any]]
    for e in events {
        let ev = EKEvent(eventStore: store)
        ev.calendar = cal
        ev.title = e["title"] as? String
        if e["all_day"] as? Bool == true {
            ev.isAllDay = true
            ev.startDate = dayFormatter().date(from: e["start_date"] as! String)!
            ev.endDate = dayFormatter().date(from: e["end_date"] as! String)!
        } else {
            ev.startDate = parseISO(e["start"] as! String)
            ev.endDate = parseISO(e["end"] as! String)
            ev.timeZone = TimeZone(identifier: e["time_zone"] as! String)
        }
        ev.location = nonEmpty(e["location"])
        ev.notes = nonEmpty(e["notes"])
        if let r = e["recurrence"] as? [String: Any] {
            guard r["frequency"] as? String == "weekly" else { fail("only weekly recurrence is supported") }
            ev.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: r["interval"] as! Int,
                                                  end: EKRecurrenceEnd(occurrenceCount: r["count"] as! Int)))
        }
        try store.save(ev, span: .futureEvents, commit: false)
        created.append((e["key"] as! String, ev))
    }
    try store.commit()
    var eventState: [String: Any] = [:]
    for (key, ev) in created {
        eventState[key] = ["id": ev.eventIdentifier ?? "", "external_id": ev.calendarItemExternalIdentifier ?? ""]
    }
    state["calendar"] = ["id": cal.calendarIdentifier, "title": marker]
    state["events"] = eventState

    // reminders
    let list = EKCalendar(for: .reminder, eventStore: store)
    list.title = marker
    list.source = source(store, .reminder)
    try store.saveCalendar(list, commit: true)
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = dueZone
    var createdReminders: [(String, EKReminder)] = []
    let items = (manifest["reminders"] as! [String: Any])["items"] as! [[String: Any]]
    for r in items {
        let rem = EKReminder(eventStore: store)
        rem.calendar = list
        rem.title = r["title"] as? String
        rem.notes = nonEmpty(r["notes"])
        rem.priority = r["priority"] as! Int
        if let due = r["due"] as? String {
            var comps = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parseISO(due))
            comps.timeZone = dueZone
            rem.dueDateComponents = comps
        }
        if let done = r["completion_date"] as? String { rem.completionDate = parseISO(done) }
        try store.save(rem, commit: false)
        createdReminders.append((r["key"] as! String, rem))
    }
    try store.commit()
    var reminderState: [String: Any] = [:]
    for (key, rem) in createdReminders {
        reminderState[key] = ["id": rem.calendarItemIdentifier, "external_id": rem.calendarItemExternalIdentifier ?? ""]
    }
    state["reminder_list"] = ["id": list.calendarIdentifier, "title": marker]
    state["reminders"] = reminderState

    // contacts and group
    let request = CNSaveRequest()
    let group = CNMutableGroup()
    group.name = marker
    request.add(group, toContainerWithIdentifier: nil)
    var createdContacts: [(String, CNMutableContact)] = []
    let people = (manifest["contacts"] as! [String: Any])["people"] as! [[String: Any]]
    for p in people {
        let c = CNMutableContact()
        c.givenName = p["given_name"] as! String
        c.familyName = p["family_name"] as! String
        c.organizationName = p["organization"] as! String
        c.emailAddresses = (p["emails"] as! [String]).map { CNLabeledValue(label: CNLabelWork, value: $0 as NSString) }
        c.phoneNumbers = (p["phones"] as! [String]).map {
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0))
        }
        request.add(c, toContainerWithIdentifier: nil)
        request.addMember(c, to: group)
        createdContacts.append((p["key"] as! String, c))
    }
    try contacts.execute(request)
    var contactState: [String: Any] = [:]
    for (key, c) in createdContacts { contactState[key] = ["id": c.identifier] }
    state["contact_group"] = ["id": group.identifier, "name": marker]
    state["contacts"] = contactState
    emit(state)
}

// ---------------------------------------------------------------- dump
func dump() {
    let (store, contacts) = requireAccess()
    var out: [String: Any] = ["time_zone": TimeZone.current.identifier]
    let cals = markerCalendars(store, .event)
    out["calendars"] = cals.map { ["id": $0.calendarIdentifier, "title": $0.title] }
    var events: [[String: Any]] = []
    if !cals.isEmpty {
        let predicate = store.predicateForEvents(withStart: parseISO("2027-01-01T00:00:00Z"),
                                                 end: parseISO("2027-07-01T00:00:00Z"), calendars: cals)
        for ev in store.events(matching: predicate) {
            // A range query and a fetch by identifier can disagree (seen for an event that spans a DST change),
            // so both are reported. For a recurring event the stored values are those of the first occurrence.
            let stored = store.event(withIdentifier: ev.eventIdentifier)
            events.append([
                "stored_start_epoch": stored.map { Int($0.startDate.timeIntervalSince1970) as Any } ?? NSNull(),
                "stored_end_epoch": stored.map { Int($0.endDate.timeIntervalSince1970) as Any } ?? NSNull(),
                "id": ev.eventIdentifier ?? "", "external_id": ev.calendarItemExternalIdentifier ?? "",
                "calendar_id": ev.calendar.calendarIdentifier, "title": ev.title ?? "",
                "start_epoch": Int(ev.startDate.timeIntervalSince1970), "end_epoch": Int(ev.endDate.timeIntervalSince1970),
                "start_date": dayFormatter().string(from: ev.startDate), "end_date": dayFormatter().string(from: ev.endDate),
                "all_day": ev.isAllDay, "time_zone": ev.timeZone?.identifier ?? NSNull(),
                "location": ev.location ?? "", "notes": ev.notes ?? "", "recurring": ev.hasRecurrenceRules,
            ])
        }
    }
    out["events"] = events

    let lists = markerCalendars(store, .reminder)
    out["reminder_lists"] = lists.map { ["id": $0.calendarIdentifier, "title": $0.title] }
    out["reminders"] = fetchReminders(store, lists).map { rem -> [String: Any] in
        var due: Any = NSNull()
        if let comps = rem.dueDateComponents {
            var g = Calendar(identifier: .gregorian)
            g.timeZone = comps.timeZone ?? TimeZone.current
            if let d = g.date(from: comps) { due = Int(d.timeIntervalSince1970) }
        }
        return [
            "id": rem.calendarItemIdentifier, "list_id": rem.calendar.calendarIdentifier, "title": rem.title ?? "",
            "due_epoch": due, "due_time_zone": rem.dueDateComponents?.timeZone?.identifier ?? NSNull(),
            "priority": rem.priority, "notes": rem.notes ?? "", "completed": rem.isCompleted,
            "completion_epoch": rem.completionDate.map { Int($0.timeIntervalSince1970) as Any } ?? NSNull(),
        ]
    }

    let groups = markerGroups(contacts)
    var memberIDs = Set<String>()
    var groupOut: [[String: Any]] = []
    for g in groups {
        let members = (try? contacts.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: g.identifier),
                                                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []
        members.forEach { memberIDs.insert($0.identifier) }
        groupOut.append(["id": g.identifier, "name": g.name, "member_count": members.count])
    }
    out["contact_groups"] = groupOut
    out["contacts"] = prefixedContacts(contacts).map { c -> [String: Any] in
        ["id": c.identifier, "given_name": c.givenName, "family_name": c.familyName, "organization": c.organizationName,
         "emails": c.emailAddresses.map { $0.value as String }, "phones": c.phoneNumbers.map { $0.value.stringValue },
         "in_group": memberIDs.contains(c.identifier)]
    }
    emit(out)
}

// ---------------------------------------------------------------- teardown
func ids(_ state: [String: Any], _ section: String) -> [String] {
    ((state[section] as? [String: Any]) ?? [:]).values.compactMap { ($0 as? [String: Any])?["id"] as? String }
}

func teardown(_ statePath: String) throws {
    let state = loadJSON(statePath)
    let (store, contacts) = requireAccess()
    let calendarIDs = ["calendar", "reminder_list"].compactMap { (state[$0] as? [String: Any])?["id"] as? String }
    for id in calendarIDs {
        if let cal = store.calendar(withIdentifier: id) { try store.removeCalendar(cal, commit: true) }
    }
    let contactIDs = ids(state, "contacts")
    let groupID = (state["contact_group"] as? [String: Any])?["id"] as? String
    let request = CNSaveRequest()
    let found = (try? contacts.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: contactIDs),
                                              keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []
    for c in found { request.delete(c.mutableCopy() as! CNMutableContact) }
    if let groupID, let g = (try? contacts.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [groupID])))?.first {
        request.delete(g.mutableCopy() as! CNMutableGroup)
    }
    try contacts.execute(request)

    // verify by identifier with fresh stores
    let check = EKEventStore()
    let checkContacts = CNContactStore()
    var remaining: [String] = []
    for id in calendarIDs where check.calendar(withIdentifier: id) != nil { remaining.append("calendar:" + id) }
    for id in ids(state, "events") where check.event(withIdentifier: id) != nil { remaining.append("event:" + id) }
    for id in ids(state, "reminders") where check.calendarItem(withIdentifier: id) != nil { remaining.append("reminder:" + id) }
    let left = (try? checkContacts.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: contactIDs),
                                                  keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []
    remaining += left.map { "contact:" + $0.identifier }
    if let groupID, let groups = try? checkContacts.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [groupID])), !groups.isEmpty {
        remaining.append("group:" + groupID)
    }
    emit(["checked": calendarIDs.count + ids(state, "events").count + ids(state, "reminders").count + contactIDs.count + (groupID == nil ? 0 : 1),
          "remaining": remaining])
    if !remaining.isEmpty { exit(1) }
}

// ---------------------------------------------------------------- typedstream (attributedBody) helpers
func readStdinArray() -> [String] {
    guard let arr = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String] else {
        fail("stdin must be a JSON array of strings")
    }
    return arr
}

// NSArchiver is hidden from Swift but still ships in Foundation; it is what Messages uses for attributedBody.
func typedstream() {
    let archiver: AnyObject = NSClassFromString("NSArchiver")!
    let key = NSAttributedString.Key("__kIMMessagePartAttributeName")
    emit(readStdinArray().map { text -> String in
        let attributed = NSAttributedString(string: text, attributes: [key: NSNumber(value: 0)])
        let data = archiver.perform(NSSelectorFromString("archivedDataWithRootObject:"), with: attributed)!.takeUnretainedValue() as! Data
        return data.map { String(format: "%02x", $0) }.joined()
    })
}

func untypedstream() {
    let unarchiver: AnyObject = NSClassFromString("NSUnarchiver")!
    emit(readStdinArray().map { hex -> String in
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        let obj = unarchiver.perform(NSSelectorFromString("unarchiveObjectWithData:"), with: Data(bytes))?.takeUnretainedValue()
        return (obj as? NSAttributedString)?.string ?? "<not an attributed string>"
    })
}

// ---------------------------------------------------------------- main
let args = CommandLine.arguments
do {
    switch args.count > 1 ? args[1] : "" {
    case "seed" where args.count == 3: try seed(args[2])
    case "dump": dump()
    case "teardown" where args.count == 3: try teardown(args[2])
    case "typedstream": typedstream()
    case "untypedstream": untypedstream()
    default: fail("usage: pb-seed seed <manifest.json> | dump | teardown <state.json> | typedstream | untypedstream")
    }
} catch {
    fail("\(error)")
}
