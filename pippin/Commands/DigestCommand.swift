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
        guard calendarDays > 0, calendarDays <= 366 else {
            throw ValidationError("--calendar-days must be between 1 and 366.")
        }
        let validSections: Set = ["mail", "calendar", "reminders", "notes"]
        for section in skip {
            guard validSections.contains(section) else {
                throw ValidationError("Unknown section '\(section)'. Valid values: mail, calendar, reminders, notes.")
            }
        }
    }

    /// End of the "upcoming" calendar window. `calendarDays` is days *beyond
    /// today*, so the window spans the next `calendarDays` full days measured
    /// from end-of-today — `--calendar-days 7` covers the next 7 days, not 6.
    /// (Anchoring to start-of-today instead dropped the last requested day.)
    /// Returns nil only if the date arithmetic overflows (`calendarDays` is
    /// bounded in `validate()`, so that never happens via the CLI).
    static func upcomingWindowEnd(endOfToday: Date, calendarDays: Int, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: calendarDays, to: endOfToday)
    }

    public mutating func run() async throws {
        var warnings: [String] = []
        let skipSet = Set(skip)
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!

        // Mail

        var mailSection = DigestPayload.MailSection(totalUnread: 0, perAccount: [])
        if !skipSet.contains("mail") {
            do {
                // listAccounts/listMessages spawn blocking osascript subprocesses;
                // hop off the cooperative pool so concurrent callers don't stall.
                let accounts = try await detachBlocking { try MailBridge.listAccounts() }
                var summaries: [DigestPayload.AccountSummary] = []
                for account in accounts {
                    do {
                        let accountName = account.name
                        let limit = mailLimit
                        let outcome = try await detachBlocking {
                            try MailBridge.listMessages(
                                account: accountName,
                                mailbox: "INBOX",
                                unread: true,
                                limit: limit
                            )
                        }
                        if outcome.timedOut {
                            warnings.append("mail (\(account.name)): unread count may be partial — scan timed out")
                        }
                        summaries.append(DigestPayload.AccountSummary(
                            account: account.name,
                            unread: outcome.messages.count,
                            topMessages: outcome.messages
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

        // Calendar

        var calendarSection = DigestPayload.CalendarSection(today: [], upcoming: [])
        if !skipSet.contains("calendar") {
            do {
                let bridge = CalendarBridge()
                // `calendarDays` is "days beyond today", so the upcoming window
                // is the next `calendarDays` full days starting at end-of-today.
                // Anchoring to `startOfDay` instead dropped the last day (a 7-day
                // request only covered 6). `calendarDays` is bounded in validate(),
                // so date(byAdding:) can't overflow to nil here.
                guard let upcomingEnd = Self.upcomingWindowEnd(endOfToday: endOfDay, calendarDays: calendarDays, calendar: cal) else {
                    throw CalendarBridgeError.dateParseError("could not compute the \(calendarDays)-day upcoming window")
                }
                async let todayEvents = bridge.listEvents(from: startOfDay, to: endOfDay)
                async let upcomingEvents = bridge.listEvents(from: endOfDay, to: upcomingEnd)
                let (today, upcoming) = try await (todayEvents, upcomingEvents)
                calendarSection = DigestPayload.CalendarSection(today: today, upcoming: upcoming)
            } catch {
                warnings.append("calendar: \(error.localizedDescription)")
            }
        }

        // Reminders

        var remindersSection = DigestPayload.RemindersSection(dueToday: [], overdue: [])
        if !skipSet.contains("reminders") {
            do {
                let bridge = RemindersBridge()
                let allReminders = try await bridge.listReminders(completed: false, limit: 500)
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

        // Notes

        var notesSection = DigestPayload.NotesSection(recent: [])
        if !skipSet.contains("notes") {
            do {
                let notesLimit = self.notesLimit
                // listNotes spawns a blocking osascript subprocess; hop off the
                // cooperative pool so concurrent callers don't stall.
                let outcome = try await detachBlocking { try NotesBridge.listNotes(limit: notesLimit) }
                if outcome.timedOut {
                    warnings.append("notes: scan timed out — recent notes may be missing or unsorted")
                }
                notesSection = DigestPayload.NotesSection(recent: outcome.results.map { NoteDigestInfo(from: $0) })
            } catch {
                warnings.append("notes: \(error.localizedDescription)")
            }
        }

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
            try output.printAgent(payload)
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
