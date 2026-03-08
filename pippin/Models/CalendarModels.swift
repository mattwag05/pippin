import Foundation

public struct CalendarInfo: Codable, Sendable {
    public let id: String
    public let title: String
    public let type: String
    public let color: String
    public let account: String

    public init(id: String, title: String, type: String, color: String, account: String) {
        self.id = id
        self.title = title
        self.type = type
        self.color = color
        self.account = account
    }
}

public struct CalendarEvent: Codable, Sendable {
    public let id: String
    public let calendarId: String
    public let calendarTitle: String
    public let title: String
    public let startDate: String
    public let endDate: String
    public let isAllDay: Bool
    public let location: String?
    public let notes: String?
    public let url: String?
    public let attendees: [Attendee]?
    public let recurrence: String?
    public let status: String
    public let alerts: [String]?

    public init(
        id: String,
        calendarId: String,
        calendarTitle: String,
        title: String,
        startDate: String,
        endDate: String,
        isAllDay: Bool,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        attendees: [Attendee]? = nil,
        recurrence: String? = nil,
        status: String = "none",
        alerts: [String]? = nil
    ) {
        self.id = id
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
        self.recurrence = recurrence
        self.status = status
        self.alerts = alerts
    }
}

public struct Attendee: Codable, Sendable {
    public let name: String?
    public let email: String?
    public let status: String

    public init(name: String?, email: String?, status: String) {
        self.name = name
        self.email = email
        self.status = status
    }
}

public struct CalendarActionResult: Codable, Sendable {
    public let success: Bool
    public let action: String
    public let details: [String: String]

    public init(success: Bool, action: String, details: [String: String]) {
        self.success = success
        self.action = action
        self.details = details
    }
}
