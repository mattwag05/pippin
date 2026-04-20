import Foundation

/// Aggregated daily digest payload returned by `pippin digest`.
public struct DigestPayload: Codable, Sendable {
    public let generatedAt: String // ISO 8601
    public let mail: MailSection
    public let calendar: CalendarSection
    public let reminders: RemindersSection
    public let notes: NotesSection
    /// Partial-failure messages — populated when a section errors but others succeed.
    public let warnings: [String]

    public init(
        generatedAt: String,
        mail: MailSection,
        calendar: CalendarSection,
        reminders: RemindersSection,
        notes: NotesSection,
        warnings: [String]
    ) {
        self.generatedAt = generatedAt
        self.mail = mail
        self.calendar = calendar
        self.reminders = reminders
        self.notes = notes
        self.warnings = warnings
    }

    public struct MailSection: Codable, Sendable {
        public let totalUnread: Int
        public let perAccount: [AccountSummary]

        public init(totalUnread: Int, perAccount: [AccountSummary]) {
            self.totalUnread = totalUnread
            self.perAccount = perAccount
        }
    }

    public struct AccountSummary: Codable, Sendable {
        public let account: String
        public let unread: Int
        public let topMessages: [MailMessage]

        public init(account: String, unread: Int, topMessages: [MailMessage]) {
            self.account = account
            self.unread = unread
            self.topMessages = topMessages
        }
    }

    public struct CalendarSection: Codable, Sendable {
        public let today: [CalendarEvent]
        /// Events after today, up to --calendar-days.
        public let upcoming: [CalendarEvent]

        public init(today: [CalendarEvent], upcoming: [CalendarEvent]) {
            self.today = today
            self.upcoming = upcoming
        }
    }

    public struct RemindersSection: Codable, Sendable {
        public let dueToday: [ReminderItem]
        public let overdue: [ReminderItem]

        public init(dueToday: [ReminderItem], overdue: [ReminderItem]) {
            self.dueToday = dueToday
            self.overdue = overdue
        }
    }

    public struct NotesSection: Codable, Sendable {
        public let recent: [NoteDigestInfo]

        public init(recent: [NoteDigestInfo]) {
            self.recent = recent
        }
    }
}

/// Slim Note view for digest output — omits the large HTML body field.
public struct NoteDigestInfo: Codable, Sendable {
    public let id: String
    public let title: String
    public let folder: String
    public let modificationDate: String
    public let plainText: String

    public init(id: String, title: String, folder: String, modificationDate: String, plainText: String) {
        self.id = id
        self.title = title
        self.folder = folder
        self.modificationDate = modificationDate
        self.plainText = plainText
    }

    init(from note: NoteInfo) {
        id = note.id
        title = note.title
        folder = note.folder
        modificationDate = note.modificationDate
        plainText = note.plainText
    }
}
