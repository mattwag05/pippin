import ArgumentParser
import Foundation

public struct DigestCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "digest",
        abstract: "Aggregated daily digest: unread mail, today's calendar, due reminders, and recent notes."
    )

    @Option(name: .long, help: "Max unread messages per mail account (default: 5).")
    public var mailLimit: Int = 5

    @Option(name: .long, help: "Max recent notes to include (default: 5).")
    public var notesLimit: Int = 5

    @Option(name: .long, help: "Days of upcoming calendar events beyond today (default: 7).")
    public var calendarDays: Int = 7

    @Option(name: .long, parsing: .upToNextOption, help: "Sections to skip: mail, calendar, reminders, notes.")
    public var skip: [String] = []

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func validate() throws {
        guard mailLimit > 0 else {
            throw ValidationError("--mail-limit must be positive.")
        }
        guard notesLimit > 0 else {
            throw ValidationError("--notes-limit must be positive.")
        }
        guard calendarDays > 0 else {
            throw ValidationError("--calendar-days must be positive.")
        }
        let validSections: Set = ["mail", "calendar", "reminders", "notes"]
        for section in skip {
            guard validSections.contains(section) else {
                throw ValidationError("Unknown section '\(section)'. Valid values: mail, calendar, reminders, notes.")
            }
        }
    }

    public mutating func run() async throws {
        var warnings: [String] = []
        let skipSet = Set(skip)

        // MARK: Mail

        var mailSection = DigestPayload.MailSection(totalUnread: 0, perAccount: [])
        if !skipSet.contains("mail") {
            do {
                let accounts = try MailBridge.listAccounts()
                var summaries: [DigestPayload.AccountSummary] = []
                for account in accounts {
                    do {
                        let messages = try MailBridge.listMessages(
                            account: account.name,
                            mailbox: "INBOX",
                            unread: true,
                            limit: mailLimit
                        )
                        summaries.append(DigestPayload.AccountSummary(
                            account: account.name,
                            unread: messages.count,
                            topMessages: messages
                        ))
                    } catch {
                        warnings.append("mail (\(account.name)): \(error.localizedDescription)")
                    }
                }
                let totalUnread = summaries.reduce(0) { $0 + $1.unread }
                mailSection = DigestPayload.MailSection(totalUnread: totalUnread, perAccount: summaries)
            } catch {
                warnings.append("mail: \(error.localizedDescription)")
            }
        }

        // MARK: Calendar

        var calendarSection = DigestPayload.CalendarSection(today: [], upcoming: [])
        if !skipSet.contains("calendar") {
            do {
                let bridge = CalendarBridge()
                let cal = Calendar.current
                let startOfDay = cal.startOfDay(for: Date())
                let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
                let upcomingEnd = cal.date(byAdding: .day, value: calendarDays, to: startOfDay)!
                let todayEvents = try await bridge.listEvents(from: startOfDay, to: endOfDay)
                let upcomingEvents = try await bridge.listEvents(from: endOfDay, to: upcomingEnd)
                calendarSection = DigestPayload.CalendarSection(today: todayEvents, upcoming: upcomingEvents)
            } catch {
                warnings.append("calendar: \(error.localizedDescription)")
            }
        }

        // MARK: Reminders

        var remindersSection = DigestPayload.RemindersSection(dueToday: [], overdue: [])
        if !skipSet.contains("reminders") {
            do {
                let bridge = RemindersBridge()
                let allReminders = try await bridge.listReminders(completed: false, limit: 500)
                let cal = Calendar.current
                let startOfDay = cal.startOfDay(for: Date())
                let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
                let dueToday = allReminders.filter { r in
                    guard let due = r.dueDate, let date = parseCalendarDate(due) else { return false }
                    return date >= startOfDay && date < endOfDay
                }
                let overdue = allReminders.filter { r in
                    guard let due = r.dueDate, let date = parseCalendarDate(due) else { return false }
                    return date < startOfDay
                }
                remindersSection = DigestPayload.RemindersSection(dueToday: dueToday, overdue: overdue)
            } catch {
                warnings.append("reminders: \(error.localizedDescription)")
            }
        }

        // MARK: Notes

        var notesSection = DigestPayload.NotesSection(recent: [])
        if !skipSet.contains("notes") {
            do {
                let notes = try NotesBridge.listNotes(limit: notesLimit)
                notesSection = DigestPayload.NotesSection(recent: notes.map { NoteDigestInfo(from: $0) })
            } catch {
                warnings.append("notes: \(error.localizedDescription)")
            }
        }

        // MARK: Output

        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let payload = DigestPayload(
            generatedAt: generatedAt,
            mail: mailSection,
            calendar: calendarSection,
            reminders: remindersSection,
            notes: notesSection,
            warnings: warnings
        )

        if output.isAgent {
            try printAgentJSON(payload)
        } else if output.isJSON {
            try printJSON(payload)
        } else {
            printDigestText(payload)
        }
    }
}

// MARK: - Text formatter

private func printDigestText(_ payload: DigestPayload) {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, MMM d 'at' h:mm a"
    print("Digest — \(f.string(from: Date()))\n")

    // Mail
    print("MAIL")
    if payload.mail.perAccount.isEmpty {
        print("  No accounts.")
    } else {
        print("  \(payload.mail.totalUnread) unread total")
        for summary in payload.mail.perAccount {
            print("  \(summary.account): \(summary.unread) unread")
            for msg in summary.topMessages {
                print("    • \(msg.subject) — \(msg.from)")
            }
        }
    }
    print("")

    // Calendar — Today
    print("CALENDAR — TODAY")
    if payload.calendar.today.isEmpty {
        print("  No events today.")
    } else {
        for event in payload.calendar.today {
            let time = event.isAllDay ? "all day" : TextFormatter.compactDate(event.startDate)
            print("  • \(event.title) (\(time))")
        }
    }
    print("")

    // Calendar — Upcoming
    print("CALENDAR — UPCOMING")
    if payload.calendar.upcoming.isEmpty {
        print("  Nothing upcoming.")
    } else {
        for event in payload.calendar.upcoming {
            let time = event.isAllDay ? "all day" : TextFormatter.compactDate(event.startDate)
            print("  • \(event.title) (\(time)) [\(event.calendarTitle)]")
        }
    }
    print("")

    // Reminders
    print("REMINDERS")
    if payload.reminders.overdue.isEmpty, payload.reminders.dueToday.isEmpty {
        print("  None due.")
    } else {
        if !payload.reminders.overdue.isEmpty {
            print("  Overdue (\(payload.reminders.overdue.count)):")
            for r in payload.reminders.overdue {
                print("    • \(r.title)")
            }
        }
        if !payload.reminders.dueToday.isEmpty {
            print("  Due today (\(payload.reminders.dueToday.count)):")
            for r in payload.reminders.dueToday {
                print("    • \(r.title)")
            }
        }
    }
    print("")

    // Notes
    print("NOTES — RECENT")
    if payload.notes.recent.isEmpty {
        print("  No recent notes.")
    } else {
        for note in payload.notes.recent {
            print("  • \(note.title) [\(note.folder)]")
        }
    }

    if !payload.warnings.isEmpty {
        print("")
        print("WARNINGS")
        for w in payload.warnings {
            print("  ⚠ \(w)")
        }
    }
}
