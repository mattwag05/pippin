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
        /// `true` when either the folder enumeration or note enumeration hit
        /// the JXA soft-cap and returned partial results. Means `noteCount`
        /// and `folderCount` may understate reality.
        public let timedOut: Bool

        public init(noteCount: Int, folderCount: Int, timedOut: Bool = false) {
            self.noteCount = noteCount
            self.folderCount = folderCount
            self.timedOut = timedOut
        }
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
    /// `true` when at least one section was dropped because the whole-dashboard
    /// wall-clock budget elapsed (pippin-0nk). The dropped section reads as
    /// `nil`; this flag tells callers the dashboard is partial, not empty.
    public let timedOut: Bool

    public init(
        version: String,
        mail: MailStatus?,
        calendar: CalendarStatus?,
        reminders: RemindersStatus?,
        memos: MemosStatus?,
        notes: NotesStatus?,
        contacts: ContactsStatus?,
        permissions: [PermissionEntry],
        timedOut: Bool = false
    ) {
        self.version = version
        self.mail = mail
        self.calendar = calendar
        self.reminders = reminders
        self.memos = memos
        self.notes = notes
        self.contacts = contacts
        self.permissions = permissions
        self.timedOut = timedOut
    }
}

public struct StatusCommand: AgentCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show a system dashboard: accounts, events, reminders, permissions."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func execute() async throws -> AgentResult {
        // MCP caps the whole dashboard at 50s (under the 60s runChild cap) so a
        // slow section yields partial results instead of a SIGKILL; CLI is
        // unbounded. See pippin-0nk.
        let budgetMs = BatchBudget.forCurrentContext().softTimeoutMs
        let report = await detachBlocking { buildStatusReport(budgetMs: budgetMs) }

        return .emit(
            report,
            timedOut: report.timedOut,
            timedOutHint: "status exceeded its \(budgetMs)ms budget; some sections were skipped"
        )
    }
}

// MARK: - Report Building

/// Everything `status` reads from outside the process, as replaceable probes.
/// The Mail account list and the Notes folder list each feed a section AND the
/// permissions table, so each is asked for once and shared.
struct StatusProbes: Sendable {
    var mailAccounts: @Sendable () -> [MailAccount]? = { try? MailBridge.listAccounts() }
    var mailboxCounts: @Sendable ([MailAccount]) -> [String: Int] = { MailBridge.mailboxCounts(for: $0) }
    var notesFolders: @Sendable () -> BridgeOutcome<[NoteFolder]>? = { try? NotesBridge.listFolders() }
    /// One Apple Event (`app.notes().length`): listing notes to count them
    /// hit the script cap on large vaults and dragged status to ~84s.
    var notesCount: @Sendable () -> Int? = { try? NotesBridge.countNotes() }
    var calendar: @Sendable () -> StatusReport.CalendarStatus? = gatherCalendarStatus
    var reminders: @Sendable () -> StatusReport.RemindersStatus? = gatherRemindersStatus
    var memos: @Sendable () -> StatusReport.MemosStatus? = gatherMemosStatus
    var contacts: @Sendable () -> StatusReport.ContactsStatus? = gatherContactsStatus
    var memosReadable: @Sendable () -> Bool = {
        (try? VoiceMemosDB(dbPath: VoiceMemosDB.defaultDBPath())) != nil
    }

    static let live = StatusProbes()
}

/// Gathers every section concurrently and bounds the total wait by `budgetMs`.
/// The sections are independent subsystems, so running them in parallel turns
/// the old sequential sum (which blew past the MCP runChild cap on multi-account
/// setups) into the cost of the single slowest section. A section that misses
/// the budget is left `nil` and `timedOut` is set. See pippin-0nk.
func buildStatusReport(budgetMs: Int, probes: StatusProbes = .live) -> StatusReport {
    // Outer optional: `nil` = the probe missed the budget. Inner: `nil` = it
    // ran but there is no access.
    let accounts = ConcurrentSlot<[MailAccount]?>()
    let mail = ConcurrentSlot<StatusReport.MailStatus?>()
    let calendar = ConcurrentSlot<StatusReport.CalendarStatus?>()
    let reminders = ConcurrentSlot<StatusReport.RemindersStatus?>()
    let memos = ConcurrentSlot<StatusReport.MemosStatus?>()
    let folders = ConcurrentSlot<BridgeOutcome<[NoteFolder]>?>()
    let noteCount = ConcurrentSlot<Int?>()
    let contacts = ConcurrentSlot<StatusReport.ContactsStatus?>()
    let memosReadable = ConcurrentSlot<Bool>()

    let completed = runConcurrentlyWithBudget(budgetMs: budgetMs, [
        {
            let found = probes.mailAccounts()
            accounts.set(found)
            mail.set(found.map { mailStatus(accounts: $0, counts: probes.mailboxCounts($0)) })
        },
        { calendar.set(probes.calendar()) },
        { reminders.set(probes.reminders()) },
        {
            // One after the other: two connections opening the live Voice
            // Memos database at the same moment can fail one of them.
            memos.set(probes.memos())
            memosReadable.set(probes.memosReadable())
        },
        { folders.set(probes.notesFolders()) },
        { noteCount.set(probes.notesCount()) },
        { contacts.set(probes.contacts()) },
    ])

    // The table needs both shared probes and the memos probe; if any missed
    // the budget it is left empty, as it was when it ran as one task.
    var permissions: [StatusReport.PermissionEntry] = []
    if let accounts = accounts.get(), let folders = folders.get(), let memosOK = memosReadable.get() {
        permissions = permissionEntries(mailOK: accounts != nil, memosOK: memosOK, notesOK: folders != nil)
    }

    return StatusReport(
        version: PippinVersion.version,
        // A section is `nil` when it missed the budget or has no access; only
        // the former trips `timedOut` (via `completed`).
        mail: mail.get() ?? nil,
        calendar: calendar.get() ?? nil,
        reminders: reminders.get() ?? nil,
        memos: memos.get() ?? nil,
        notes: (folders.get() ?? nil).map { notesStatus(folders: $0, count: noteCount.get() ?? nil) },
        contacts: contacts.get() ?? nil,
        permissions: permissions,
        timedOut: !completed
    )
}

// MARK: - Mail

/// `counts` comes from one Envelope Index scan for all accounts (fast path),
/// falling back to per-account JXA: N serial Apple Events dominated status.
private func mailStatus(accounts: [MailAccount], counts: [String: Int]) -> StatusReport.MailStatus {
    let summaries = accounts.map { account in
        StatusReport.MailAccountSummary(
            name: account.name,
            email: account.email,
            mailboxCount: counts[account.name] ?? 0
        )
    }
    return StatusReport.MailStatus(accounts: summaries)
}

// MARK: - Calendar

private func gatherCalendarStatus() -> StatusReport.CalendarStatus? {
    // We need to read events, so .writeOnly isn't enough. .authorized was the
    // pre-macOS-14 spelling; deprecated since we target macOS 15+.
    let ekStatus = EKEventStore.authorizationStatus(for: .event)
    guard ekStatus == .fullAccess else { return nil }

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
    guard ekStatus == .fullAccess else { return nil }

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

/// A count that failed or did not finish reads as 0 and marks the section
/// partial, the same as a folder enumeration that hit the soft cap.
private func notesStatus(folders: BridgeOutcome<[NoteFolder]>, count: Int?) -> StatusReport.NotesStatus {
    StatusReport.NotesStatus(
        noteCount: count ?? 0,
        folderCount: folders.results.count,
        timedOut: folders.timedOut || count == nil
    )
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

private func permissionEntries(mailOK: Bool, memosOK: Bool, notesOK: Bool) -> [StatusReport.PermissionEntry] {
    [
        StatusReport.PermissionEntry(name: "Mail", granted: mailOK),
        StatusReport.PermissionEntry(
            name: "Calendar", granted: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        ),
        StatusReport.PermissionEntry(
            name: "Reminders", granted: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        ),
        StatusReport.PermissionEntry(
            name: "Contacts", granted: CNContactStore.authorizationStatus(for: .contacts) == .authorized
        ),
        StatusReport.PermissionEntry(name: "Voice Memos", granted: memosOK),
        StatusReport.PermissionEntry(name: "Notes", granted: notesOK),
    ]
}
