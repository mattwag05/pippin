import EventKit
import Foundation

public final class RemindersBridge: @unchecked Sendable {
    private let store: EKEventStore

    public init() {
        store = EKEventStore()
    }

    // MARK: - Access

    public func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess:
            return
        case .authorized: // deprecated but handle defensively
            return
        case .notDetermined:
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
        priority: Int? = nil,
        limit: Int = 50
    ) async throws -> [ReminderItem] {
        try await ensureAccess()

        var filterCalendars: [EKCalendar]?
        if let listId {
            guard let cal = store.calendar(withIdentifier: listId) else {
                throw RemindersBridgeError.listNotFound(listId)
            }
            filterCalendars = [cal]
        }

        let predicate = store.predicateForReminders(in: filterCalendars)
        let allReminders = fetchRemindersSync(predicate: predicate)

        var filtered = allReminders.filter { $0.isCompleted == completed }

        if let dueBefore {
            filtered = filtered.filter { reminder in
                guard let components = reminder.dueDateComponents,
                      let date = Calendar.current.date(from: components) else { return true }
                return date < dueBefore
            }
        }
        if let dueAfter {
            filtered = filtered.filter { reminder in
                guard let components = reminder.dueDateComponents,
                      let date = Calendar.current.date(from: components) else { return true }
                return date > dueAfter
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

        return filtered.map { mapReminder($0) }
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
    ) async throws -> ReminderActionResult {
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
            guard let cal = store.calendar(withIdentifier: listId) else {
                throw RemindersBridgeError.listNotFound(listId)
            }
            reminder.calendar = cal
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersBridgeError.saveFailed(error.localizedDescription)
        }
        return ReminderActionResult(
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
        listId: String? = nil
    ) async throws -> ReminderActionResult {
        try await ensureAccess()
        guard let reminder = try findReminderByPrefix(id: id) else {
            throw RemindersBridgeError.reminderNotFound(id)
        }
        if let title { reminder.title = title }
        if let notes { reminder.notes = notes }
        if let priority { reminder.priority = priority }
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: dueDate
            )
        }
        if let listId {
            guard let cal = store.calendar(withIdentifier: listId) else {
                throw RemindersBridgeError.listNotFound(listId)
            }
            reminder.calendar = cal
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersBridgeError.saveFailed(error.localizedDescription)
        }
        return ReminderActionResult(
            success: true,
            action: "update",
            details: ["id": reminder.calendarItemIdentifier, "title": reminder.title ?? ""]
        )
    }

    // MARK: - Complete

    public func completeReminder(id: String) async throws -> ReminderActionResult {
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
        return ReminderActionResult(
            success: true,
            action: "complete",
            details: ["id": reminder.calendarItemIdentifier, "title": reminder.title ?? ""]
        )
    }

    // MARK: - Delete

    public func deleteReminder(id: String) async throws -> ReminderActionResult {
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
        return ReminderActionResult(
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
    ) async throws -> [ReminderItem] {
        try await ensureAccess()

        var filterCalendars: [EKCalendar]?
        if let listId {
            guard let cal = store.calendar(withIdentifier: listId) else {
                throw RemindersBridgeError.listNotFound(listId)
            }
            filterCalendars = [cal]
        }

        let predicate = store.predicateForReminders(in: filterCalendars)
        let allReminders = fetchRemindersSync(predicate: predicate)

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

        return filtered.map { mapReminder($0) }
    }

    // MARK: - Private

    /// Fetch reminders synchronously using DispatchSemaphore to avoid Swift 6
    /// Sendable errors from passing EKReminder across continuation boundaries.
    private func fetchRemindersSync(predicate: NSPredicate) -> [EKReminder] {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [EKReminder] = []
        store.fetchReminders(matching: predicate) { fetched in
            result = fetched ?? []
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func findReminderByPrefix(id: String) throws -> EKReminder? {
        // Direct lookup first
        if let item = store.calendarItem(withIdentifier: id) as? EKReminder {
            return item
        }

        // Fetch all and prefix-match
        let predicate = store.predicateForReminders(in: nil)
        let allReminders = fetchRemindersSync(predicate: predicate)

        let matches = allReminders.filter { $0.calendarItemIdentifier.hasPrefix(id) }
        if matches.count > 1 {
            throw RemindersBridgeError.ambiguousId(id)
        }
        return matches.first
    }

    private func mapReminder(_ r: EKReminder) -> ReminderItem {
        let dueDate: String? = r.dueDateComponents.flatMap { components in
            Calendar.current.date(from: components).map { formatEventDate($0) }
        }
        let completionDate: String? = r.completionDate.map { formatEventDate($0) }
        let creationDate: String? = r.creationDate.map { formatEventDate($0) }
        let lastModifiedDate: String? = r.lastModifiedDate.map { formatEventDate($0) }

        return ReminderItem(
            id: r.calendarItemIdentifier,
            listId: r.calendar?.calendarIdentifier ?? "",
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
