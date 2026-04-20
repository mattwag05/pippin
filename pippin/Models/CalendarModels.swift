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

public struct CalendarConflict: Codable, Sendable {
    public let events: [CalendarEvent]
    public let overlapStart: String
    public let overlapEnd: String
    public let overlapMinutes: Int

    public init(events: [CalendarEvent], overlapStart: String, overlapEnd: String, overlapMinutes: Int) {
        self.events = events
        self.overlapStart = overlapStart
        self.overlapEnd = overlapEnd
        self.overlapMinutes = overlapMinutes
    }
}

// MARK: - Field filtering

public extension CalendarEvent {
    /// Encode only the specified fields to JSON. Pass nil to get all fields (standard encoding).
    func jsonData(fields: [String]?) throws -> Data {
        let encoder = JSONEncoder()
        guard let fields else {
            return try encoder.encode(self)
        }
        let eventData = try encoder.encode(self)
        guard let all = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Expected JSON object"))
        }
        var dict: [String: Any] = [:]
        for field in fields {
            if let val = all[field] {
                dict[field] = val
            }
        }
        return try JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
    }
}

public extension Array where Element == CalendarEvent {
    /// Encode each event with only the specified fields. Pass nil to get all fields.
    func jsonData(fields: [String]?) throws -> Data {
        let encoder = JSONEncoder()
        guard let fields else {
            return try encoder.encode(self)
        }
        let allDicts = try map { event -> [String: Any] in
            let eventData = try encoder.encode(event)
            guard let dict = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                throw EncodingError.invalidValue(event, .init(codingPath: [], debugDescription: "Expected JSON object"))
            }
            return fields.reduce(into: [:]) { result, field in
                if let val = dict[field] { result[field] = val }
            }
        }
        return try JSONSerialization.data(withJSONObject: allDicts, options: .sortedKeys)
    }
}
