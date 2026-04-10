import ArgumentParser
import Contacts
import EventKit
import Foundation

/// Dashboard payload for `pippin status`.
public struct StatusReport: Codable, Sendable {
    public struct MailStatus: Codable, Sendable {
        public let accounts: [MailAccountSummary]
    }

    public struct MailAccountSummary: Codable, Sendable {
        public let name: String
        public let email: String
        public let mailboxCount: Int
    }

    public struct CalendarStatus: Codable, Sendable {
        public let calendarCount: Int
        public let eventsToday: Int
        public let eventsRemaining: Int
    }

    public struct RemindersStatus: Codable, Sendable {
        public let listCount: Int
        public let incomplete: Int
        public let overdueCount: Int
    }

    public struct MemosStatus: Codable, Sendable {
        public let recordingCount: Int
    }

    public struct NotesStatus: Codable, Sendable {
        public let noteCount: Int
        public let folderCount: Int
    }

    public struct ContactsStatus: Codable, Sendable {
        public let contactCount: Int
    }

    public struct PermissionEntry: Codable, Sendable {
        public let name: String
        public let granted: Bool
    }

    public let version: String
    public let mail: MailStatus?
    public let calendar: CalendarStatus?
    public let reminders: RemindersStatus?
    public let memos: MemosStatus?
    public let notes: NotesStatus?
    public let contacts: ContactsStatus?
    public let permissions: [PermissionEntry]
}

public struct StatusCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show a system dashboard: accounts, events, reminders, permissions."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func run() async throws {
        let report = buildStatusReport()

        if output.isAgent {
            try printAgentJSON(report)
        } else if output.isJSON {
            try printJSON(report)
        } else {
            printTextReport(report)
        }
    }
}

// MARK: - Report Building

private func buildStatusReport() -> StatusReport {
    let mail = gatherMailStatus()
    let calendar = gatherCalendarStatus()
    let reminders = gatherRemindersStatus()
    let memos = gatherMemosStatus()
    let notes = gatherNotesStatus()
    let contacts = gatherContactsStatus()
    let permissions = gatherPermissions()

    return StatusReport(
        version: PippinVersion.version,
        mail: mail,
        calendar: calendar,
        reminders: reminders,
        memos: memos,
        notes: notes,
        contacts: contacts,
        permissions: permissions
    )
}

// MARK: - Mail

private func gatherMailStatus() -> StatusReport.MailStatus? {
    guard let accounts = try? MailBridge.listAccounts() else { return nil }
    let summaries = accounts.map { account -> StatusReport.MailAccountSummary in
        let mailboxCount = (try? MailBridge.listMailboxes(account: account.name))?.count ?? 0
        return StatusReport.MailAccountSummary(
            name: account.name,
            email: account.email ?? "",
            mailboxCount: mailboxCount
        )
    }
    return StatusReport.MailStatus(accounts: summaries)
}

// MARK: - Calendar

private func gatherCalendarStatus() -> StatusReport.CalendarStatus? {
    let ekStatus = EKEventStore.authorizationStatus(for: .event)
    guard ekStatus == .fullAccess || ekStatus == .authorized else { return nil }

    let store = EKEventStore()
    let calendars = store.calendars(for: .event)

    let now = Date()
    let cal = Calendar.current
    let startOfDay = cal.startOfDay(for: now)
    guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else {
        return StatusReport.CalendarStatus(calendarCount: calendars.count, eventsToday: 0, eventsRemaining: 0)
    }

    let todayPredicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
    let todayEvents = store.events(matching: todayPredicate)

    let remainingPredicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
    let remainingEvents = store.events(matching: remainingPredicate)

    return StatusReport.CalendarStatus(
        calendarCount: calendars.count,
        eventsToday: todayEvents.count,
        eventsRemaining: remainingEvents.count
    )
}

// MARK: - Reminders

private func gatherRemindersStatus() -> StatusReport.RemindersStatus? {
    let ekStatus = EKEventStore.authorizationStatus(for: .reminder)
    guard ekStatus == .fullAccess || ekStatus == .authorized else { return nil }

    let store = EKEventStore()
    let lists = store.calendars(for: .reminder)

    // Fetch incomplete reminders synchronously
    nonisolated(unsafe) var incompleteCount = 0
    nonisolated(unsafe) var overdueCount = 0
    let sem = DispatchSemaphore(value: 0)
    let predicate = store.predicateForIncompleteReminders(
        withDueDateStarting: nil, ending: nil, calendars: nil
    )
    store.fetchReminders(matching: predicate) { reminders in
        let items = reminders ?? []
        incompleteCount = items.count
        let now = Date()
        overdueCount = items.filter { r in
            guard let due = r.dueDateComponents,
                  let dueDate = Calendar.current.date(from: due)
            else { return false }
            return dueDate < now
        }.count
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + .seconds(5))

    return StatusReport.RemindersStatus(
        listCount: lists.count,
        incomplete: incompleteCount,
        overdueCount: overdueCount
    )
}

// MARK: - Memos

private func gatherMemosStatus() -> StatusReport.MemosStatus? {
    guard let db = try? VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath()),
          let recordings = try? db.listMemos(limit: 99999)
    else { return nil }
    return StatusReport.MemosStatus(recordingCount: recordings.count)
}

// MARK: - Notes

private func gatherNotesStatus() -> StatusReport.NotesStatus? {
    guard let folders = try? NotesBridge.listFolders() else { return nil }
    let noteCount = (try? NotesBridge.listNotes(folder: nil, limit: 500))?.count ?? 0
    return StatusReport.NotesStatus(noteCount: noteCount, folderCount: folders.count)
}

// MARK: - Contacts

private func gatherContactsStatus() -> StatusReport.ContactsStatus? {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    guard status == .authorized else { return nil }
    let store = CNContactStore()
    let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor])
    var count = 0
    _ = try? store.enumerateContacts(with: request) { _, _ in count += 1 }
    return StatusReport.ContactsStatus(contactCount: count)
}

// MARK: - Permissions

private func gatherPermissions() -> [StatusReport.PermissionEntry] {
    var entries: [StatusReport.PermissionEntry] = []

    // Mail — try listing accounts
    let mailOK = (try? MailBridge.listAccounts()) != nil
    entries.append(StatusReport.PermissionEntry(name: "Mail", granted: mailOK))

    // Calendar
    let calStatus = EKEventStore.authorizationStatus(for: .event)
    entries.append(StatusReport.PermissionEntry(
        name: "Calendar",
        granted: calStatus == .fullAccess || calStatus == .authorized
    ))

    // Reminders
    let remStatus = EKEventStore.authorizationStatus(for: .reminder)
    entries.append(StatusReport.PermissionEntry(
        name: "Reminders",
        granted: remStatus == .fullAccess || remStatus == .authorized
    ))

    // Contacts
    let cntStatus = CNContactStore.authorizationStatus(for: .contacts)
    entries.append(StatusReport.PermissionEntry(name: "Contacts", granted: cntStatus == .authorized))

    // Voice Memos
    let memosOK = (try? VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())) != nil
    entries.append(StatusReport.PermissionEntry(name: "Voice Memos", granted: memosOK))

    // Notes
    let notesOK = (try? NotesBridge.listFolders()) != nil
    entries.append(StatusReport.PermissionEntry(name: "Notes", granted: notesOK))

    return entries
}

// MARK: - Text Output

private func printTextReport(_ report: StatusReport) {
    print("pippin \(report.version) — status\n")

    // Mail
    if let mail = report.mail {
        print("Mail")
        if mail.accounts.isEmpty {
            print("  No accounts configured")
        } else {
            for acct in mail.accounts {
                print("  \(acct.name) (\(acct.email)) — \(acct.mailboxCount) mailboxes")
            }
        }
        print()
    }

    // Calendar
    if let cal = report.calendar {
        print("Calendar")
        print("  \(cal.calendarCount) calendars, \(cal.eventsToday) events today (\(cal.eventsRemaining) remaining)")
        print()
    }

    // Reminders
    if let rem = report.reminders {
        print("Reminders")
        var line = "  \(rem.listCount) lists, \(rem.incomplete) incomplete"
        if rem.overdueCount > 0 {
            line += " (\(rem.overdueCount) overdue)"
        }
        print(line)
        print()
    }

    // Voice Memos
    if let memos = report.memos {
        print("Voice Memos")
        print("  \(memos.recordingCount) recordings")
        print()
    }

    // Notes
    if let notes = report.notes {
        print("Notes")
        print("  \(notes.noteCount) notes in \(notes.folderCount) folders")
        print()
    }

    // Contacts
    if let contacts = report.contacts {
        print("Contacts")
        print("  \(contacts.contactCount) contacts")
        print()
    }

    // Permissions
    print("Permissions")
    for perm in report.permissions {
        let icon = perm.granted ? "✓" : "✗"
        print("  \(icon) \(perm.name)")
    }
}
