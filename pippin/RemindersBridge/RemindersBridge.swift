import EventKit
import Foundation

public final class RemindersBridge: @unchecked Sendable {
    private let store: EKEventStore

    public init() {
        store = EKEventStore()
    }

    // MARK: - Soft timeout

    /// Outcome of a reminders query whose underlying EventKit fetch is bounded
    /// by `fetchRemindersSync`'s 15s wall-clock cap. `timedOut` is surfaced as a
    /// "partial results" advisory, mirroring `ContactsBridge.Outcome` /
    /// `MailBridge.ScanOutcome`. Results are built directly in Swift, so the
    /// shared type's conditional `Decodable` conformance is never exercised here.
    public typealias Outcome<T> = BridgeOutcome<T>

    // MARK: - Access

    public func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess:
            return
        case .authorized: // deprecated but handle defensively
            return
        case .notDetermined:
            // Only block on the prompt when a user can actually answer it;
            // otherwise fail fast (requestFullAccess* hangs on an un-showable
            // dialog in non-interactive/background contexts). See pippin-0vr.
            guard PermissionPriming.canRequestAccess() else {
                throw RemindersBridgeError.accessDenied
            }
            let granted = try await store.requestFullAccessToReminders()
            guard granted else { throw RemindersBridgeError.accessDenied }
        default:
            throw RemindersBridgeError.accessDenied
        }
    }

    // MARK: - Lists

    public func listReminderLists() async throws -> [ReminderList] {
        try await ensureAccess()
        let defaultList = store.defaultCalendarForNewReminders()
        return store.calendars(for: .reminder)
            .map { cal in
                ReminderList(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    color: colorHex(cal.cgColor),
                    account: cal.source?.title ?? "",
                    isDefault: cal.calendarIdentifier == defaultList?.calendarIdentifier
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Fetch reminders

    public func listReminders(
        listId: String? = nil,
        completed: Bool = false,
        dueBefore: Date? = nil,
        dueAfter: Date? = nil,
        createdAfter: Date? = nil,
        modifiedAfter: Date? = nil,
        priority: Int? = nil,
        limit: Int = 50
    ) async throws -> Outcome<[ReminderItem]> {
        try await ensureAccess()

        var filterCalendars: [EKCalendar]?
        if let listId {
            filterCalendars = try [resolveList(listId)]
        }

        let predicate = store.predicateForReminders(in: filterCalendars)
        let fetch = fetchRemindersSync(predicate: predicate)
        let allReminders = fetch.reminders

        var filtered = allReminders.filter { $0.isCompleted == completed }

        if dueBefore != nil || dueAfter != nil {
            filtered = filtered.filter { reminder in
                let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                return Self.passesDueFilters(dueDate: due, dueBefore: dueBefore, dueAfter: dueAfter)
            }
        }
        if let createdAfter {
            filtered = filtered.filter { reminder in
                guard let created = reminder.creationDate else { return false }
                return created >= createdAfter
            }
        }
        if let modifiedAfter {
            filtered = filtered.filter { reminder in
                guard let modified = reminder.lastModifiedDate else { return false }
                return modified >= modifiedAfter
            }
        }
        if let priority {
            filtered = filtered.filter { $0.priority == priority }
        }

        // Sort: reminders with due dates first (ascending), then by creation date
        filtered.sort { a, b in
            let aDate: Date? = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let bDate: Date? = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            switch (aDate, bDate) {
            case let (.some(ad), .some(bd)): return ad < bd
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                let ac = a.creationDate ?? Date.distantPast
                let bc = b.creationDate ?? Date.distantPast
                return ac < bc
            }
        }

        if filtered.count > limit {
            filtered = Array(filtered.prefix(limit))
        }

        return Outcome(results: filtered.map { mapReminder($0) }, timedOut: fetch.timedOut)
    }

    // MARK: - Show

    public func showReminder(id: String) async throws -> ReminderItem {
        try await ensureAccess()
        guard let reminder = try findReminderByPrefix(id: id) else {
            throw RemindersBridgeError.reminderNotFound(id)
        }
        return mapReminder(reminder)
    }

    // MARK: - Create

    public func createReminder(
        title: String,
        listId: String? = nil,
        dueDate: Date? = nil,
        priority: Int = 0,
        notes: String? = nil,
        url: String? = nil
    ) async throws -> BridgeActionResult {
        try await ensureAccess()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.priority = priority
        if let urlStr = url, let parsed = URL(string: urlStr) {
            reminder.url = parsed
        }
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: dueDate
            )
        }
        if let listId {
            reminder.calendar = try resolveList(listId)
        } else {
            guard let defaultCal = store.defaultCalendarForNewReminders() else {
                throw RemindersBridgeError.noDefaultCalendar
            }
            reminder.calendar = defaultCal
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersBridgeError.saveFailed(error.localizedDescription)
        }
        return BridgeActionResult(
            success: true,
            action: "create",
            details: ["id": reminder.calendarItemIdentifier, "title": title]
        )
    }

    // MARK: - Update

    public func updateReminder(
        id: String,
        title: String? = nil,
        dueDate: Date? = nil,
        priority: Int? = nil,
        notes: String? = nil,
        listId: String? = nil,
        url: String? = nil
    ) async throws -> BridgeActionResult {
        try await ensureAccess()
        guard let reminder = try findReminderByPrefix(id: id) else {
            throw RemindersBridgeError.reminderNotFound(id)
        }
        if let title { reminder.title = title }
        if let notes { reminder.notes = notes }
        if let priority { reminder.priority = priority }
        if let urlStr = url, let parsed = URL(string: urlStr) {
            reminder.url = parsed
        }
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: dueDate
            )
        }
        if let listId {
            reminder.calendar = try resolveList(listId)
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersBridgeError.saveFailed(error.localizedDescription)
        }
        return BridgeActionResult(
            success: true,
            action: "update",
            details: ["id": reminder.calendarItemIdentifier, "title": reminder.title ?? ""]
        )
    }

    // MARK: - Complete

    public func completeReminder(id: String) async throws -> BridgeActionResult {
        try await ensureAccess()
        guard let reminder = try findReminderByPrefix(id: id) else {
            throw RemindersBridgeError.reminderNotFound(id)
        }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersBridgeError.saveFailed(error.localizedDescription)
        }
        return BridgeActionResult(
            success: true,
            action: "complete",
            details: ["id": reminder.calendarItemIdentifier, "title": reminder.title ?? ""]
        )
    }

    // MARK: - Delete

    public func deleteReminder(id: String) async throws -> BridgeActionResult {
        try await ensureAccess()
        guard let reminder = try findReminderByPrefix(id: id) else {
            throw RemindersBridgeError.reminderNotFound(id)
        }
        let savedTitle = reminder.title ?? ""
        let savedId = reminder.calendarItemIdentifier
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw RemindersBridgeError.saveFailed(error.localizedDescription)
        }
        return BridgeActionResult(
            success: true,
            action: "delete",
            details: ["id": savedId, "title": savedTitle]
        )
    }

    // MARK: - Search

    public func searchReminders(
        query: String,
        listId: String? = nil,
        completed: Bool = false,
        limit: Int = 50
    ) async throws -> Outcome<[ReminderItem]> {
        try await ensureAccess()

        var filterCalendars: [EKCalendar]?
        if let listId {
            filterCalendars = try [resolveList(listId)]
        }

        let predicate = store.predicateForReminders(in: filterCalendars)
        let fetch = fetchRemindersSync(predicate: predicate)
        let allReminders = fetch.reminders

        let q = query.lowercased()
        var filtered = allReminders.filter { reminder in
            reminder.isCompleted == completed
                && (
                    (reminder.title?.lowercased().contains(q) == true)
                        || (reminder.notes?.lowercased().contains(q) == true)
                )
        }

        if filtered.count > limit {
            filtered = Array(filtered.prefix(limit))
        }

        return Outcome(results: filtered.map { mapReminder($0) }, timedOut: fetch.timedOut)
    }

    /// Whether a reminder with the given resolved due date passes the
    /// `--due-before` / `--due-after` filters. A reminder with NO due date fails
    /// any due filter — it can't be before or after a cutoff (and must not show
    /// up in both `--due-before X` and `--due-after X`). Matches the
    /// exclude-on-missing behavior of the created/modified filters.
    static func passesDueFilters(dueDate: Date?, dueBefore: Date?, dueAfter: Date?) -> Bool {
        if let dueBefore {
            guard let dueDate, dueDate < dueBefore else { return false }
        }
        if let dueAfter {
            guard let dueDate, dueDate > dueAfter else { return false }
        }
        return true
    }

    // MARK: - Private

    /// Resolve a `--list` argument to an `EKCalendar`. `--list` takes IDs (from
    /// `pippin reminders lists`), but when the identifier lookup misses and the
    /// argument case-insensitively matches exactly ONE list's name, resolve it
    /// transparently — matching calendar's `--calendar-name` behavior, since
    /// passing a name where an ID is expected is the most common miss. An
    /// ambiguous name errors with the candidate IDs instead of guessing.
    private func resolveList(_ listId: String) throws -> EKCalendar {
        if let cal = store.calendar(withIdentifier: listId) { return cal }
        let named = store.calendars(for: .reminder)
            .filter { $0.title.caseInsensitiveCompare(listId) == .orderedSame }
        if named.count == 1 { return named[0] }
        throw RemindersBridgeError.listNotFound(
            Self.listIdMissDetail(listId, matchingIds: named.map(\.calendarIdentifier))
        )
    }

    /// Detail string for a `--list` miss: plain argument when no list has that
    /// name, or a "did you mean" hint carrying the IDs of the (multiple)
    /// same-named lists. Pure so it's unit-testable without an EKEventStore.
    static func listIdMissDetail(_ argument: String, matchingIds: [String]) -> String {
        guard !matchingIds.isEmpty else { return argument }
        return "\(argument) — \(matchingIds.count) lists are NAMED '\(argument)'; "
            + "did you mean one of the list IDs \(matchingIds.joined(separator: ", "))? "
            + "--list takes IDs from 'pippin reminders lists'."
    }

    /// Serialize a due date. EventKit distinguishes date-only due dates
    /// (`dueDateComponents` without an hour) from timed ones — emit YYYY-MM-DD
    /// (local day) for date-only so positive-UTC-offset consumers get the right
    /// calendar day, mirroring all-day event serialization.
    static func formatDueDate(_ components: DateComponents) -> String? {
        guard let date = Calendar.current.date(from: components) else { return nil }
        return components.hour == nil ? formatEventDay(date) : formatEventDate(date)
    }

    /// Fetch reminders synchronously using DispatchSemaphore to avoid Swift 6
    /// Sendable errors from passing EKReminder across continuation boundaries.
    ///
    /// Returns `timedOut == true` when EventKit's callback doesn't fire within
    /// the 15s wall-clock cap (store hang / permission edge) — callers surface
    /// it as a "partial results" advisory rather than the bridge writing to
    /// stderr directly, so MCP/agent clients get a structured warning and don't
    /// see duplicate noise (matches the `ContactsBridge.Outcome` contract).
    private func fetchRemindersSync(predicate: NSPredicate) -> (reminders: [EKReminder], timedOut: Bool) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [EKReminder] = []
        store.fetchReminders(matching: predicate) { fetched in
            result = fetched ?? []
            semaphore.signal()
        }
        // Bound the wait: if EventKit's callback never fires (store hang /
        // permission edge), return partial results instead of hanging forever.
        // Matches the 15s ceiling used elsewhere; a healthy fetch is near-instant.
        let timedOut = semaphore.wait(timeout: .now() + .seconds(15)) == .timedOut
        return (result, timedOut)
    }

    private func findReminderByPrefix(id: String) throws -> EKReminder? {
        // Direct lookup first
        if let item = store.calendarItem(withIdentifier: id) as? EKReminder {
            return item
        }

        // Fetch all and prefix-match. A 15s-timeout here just means a partial
        // set to match against (→ not-found), so the flag isn't surfaced.
        let predicate = store.predicateForReminders(in: nil)
        let allReminders = fetchRemindersSync(predicate: predicate).reminders

        let matches = allReminders.filter { $0.calendarItemIdentifier.hasPrefix(id) }
        if matches.count > 1 {
            throw RemindersBridgeError.ambiguousId(id)
        }
        return matches.first
    }

    private func mapReminder(_ r: EKReminder) -> ReminderItem {
        let dueDate: String? = r.dueDateComponents.flatMap { Self.formatDueDate($0) }
        let completionDate: String? = r.completionDate.map { formatEventDate($0) }
        let creationDate: String? = r.creationDate.map { formatEventDate($0) }
        let lastModifiedDate: String? = r.lastModifiedDate.map { formatEventDate($0) }

        return ReminderItem(
            id: r.calendarItemIdentifier,
            listId: r.calendar?.calendarIdentifier ?? "",
            listTitle: r.calendar?.title ?? "",
            title: r.title ?? "(no title)",
            notes: r.notes,
            url: r.url?.absoluteString,
            isCompleted: r.isCompleted,
            completionDate: completionDate,
            dueDate: dueDate,
            priority: r.priority,
            creationDate: creationDate,
            lastModifiedDate: lastModifiedDate
        )
    }
}
