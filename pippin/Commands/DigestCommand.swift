import ArgumentParser
import Foundation

public struct DigestCommand: AgentCommand {
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

    public mutating func execute() async throws -> AgentResult {
        let sources = Self.liveSources(mailLimit: mailLimit, notesLimit: notesLimit, calendarDays: calendarDays)
        return await AgentResult(Self.assemble(skipping: Set(skip), from: sources))
    }

    /// One section's payload with the warnings it raised, kept together so the
    /// sections can be gathered at once and still report their warnings in the
    /// fixed order mail, calendar, reminders, notes.
    struct Section<Payload: Sendable>: Sendable {
        var payload: Payload
        var warnings: [String] = []
    }

    /// Where each section comes from. Replaceable so the gathering can be
    /// tested without Mail, Calendar, Reminders or Notes.
    struct Sources: Sendable {
        var mail: @Sendable () async -> Section<DigestPayload.MailSection>
        var calendar: @Sendable () async -> Section<DigestPayload.CalendarSection>
        var reminders: @Sendable () async -> Section<DigestPayload.RemindersSection>
        var notes: @Sendable () async -> Section<DigestPayload.NotesSection>
    }

    /// Gather the four sections at once. They read four different apps and
    /// share nothing, so the digest costs its slowest section, not the sum.
    /// A skipped section is never asked for and stays empty.
    static func assemble(skipping skip: Set<String>, from sources: Sources) async -> DigestPayload {
        async let mailTask = skip.contains("mail")
            ? Section(payload: DigestPayload.MailSection(totalUnread: 0, perAccount: []))
            : sources.mail()
        async let calendarTask = skip.contains("calendar")
            ? Section(payload: DigestPayload.CalendarSection(today: [], upcoming: []))
            : sources.calendar()
        async let remindersTask = skip.contains("reminders")
            ? Section(payload: DigestPayload.RemindersSection(dueToday: [], overdue: []))
            : sources.reminders()
        async let notesTask = skip.contains("notes")
            ? Section(payload: DigestPayload.NotesSection(recent: []))
            : sources.notes()
        let (mail, calendar, reminders, notes) = await (mailTask, calendarTask, remindersTask, notesTask)
        return DigestPayload(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            mail: mail.payload,
            calendar: calendar.payload,
            reminders: reminders.payload,
            notes: notes.payload,
            warnings: mail.warnings + calendar.warnings + reminders.warnings + notes.warnings
        )
    }

    static func liveSources(mailLimit: Int, notesLimit: Int, calendarDays: Int) -> Sources {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        return Sources(
            mail: { await mailSection(limit: mailLimit) },
            calendar: {
                await calendarSection(startOfDay: startOfDay, endOfDay: endOfDay, calendarDays: calendarDays, cal: cal)
            },
            reminders: { await remindersSection(startOfDay: startOfDay, endOfDay: endOfDay) },
            notes: { await notesSection(limit: notesLimit) }
        )
    }

    private static func mailSection(limit: Int) async -> Section<DigestPayload.MailSection> {
        var section = Section(payload: DigestPayload.MailSection(totalUnread: 0, perAccount: []))
        do {
            // listAccounts/listMessages spawn blocking osascript subprocesses;
            // hop off the cooperative pool so concurrent callers don't stall.
            let accounts = try await detachBlocking { try MailBridge.listAccounts() }
            var summaries: [DigestPayload.AccountSummary] = []
            for account in accounts {
                do {
                    let accountName = account.name
                    let outcome = try await detachBlocking {
                        try MailBridge.listMessages(
                            account: accountName,
                            mailbox: "INBOX",
                            unread: true,
                            limit: limit
                        )
                    }
                    if outcome.timedOut {
                        section.warnings.append("mail (\(account.name)): unread count may be partial — scan timed out")
                    }
                    summaries.append(DigestPayload.AccountSummary(
                        account: account.name,
                        unread: outcome.messages.count,
                        topMessages: outcome.messages
                    ))
                } catch {
                    section.warnings.append("mail (\(account.name)): \(error.localizedDescription)")
                }
            }
            let totalUnread = summaries.reduce(0) { $0 + $1.unread }
            section.payload = DigestPayload.MailSection(totalUnread: totalUnread, perAccount: summaries)
        } catch {
            section.warnings.append("mail: \(error.localizedDescription)")
        }
        return section
    }

    private static func calendarSection(
        startOfDay: Date, endOfDay: Date, calendarDays: Int, cal: Calendar
    ) async -> Section<DigestPayload.CalendarSection> {
        var section = Section(payload: DigestPayload.CalendarSection(today: [], upcoming: []))
        do {
            let bridge = CalendarBridge()
            // `calendarDays` is "days beyond today", so the upcoming window
            // is the next `calendarDays` full days starting at end-of-today.
            // Anchoring to `startOfDay` instead dropped the last day (a 7-day
            // request only covered 6). `calendarDays` is bounded in validate(),
            // so date(byAdding:) can't overflow to nil here.
            guard let upcomingEnd = upcomingWindowEnd(endOfToday: endOfDay, calendarDays: calendarDays, calendar: cal) else {
                throw CalendarBridgeError.dateParseError("could not compute the \(calendarDays)-day upcoming window")
            }
            async let todayEvents = bridge.listEvents(from: startOfDay, to: endOfDay)
            async let upcomingEvents = bridge.listEvents(from: endOfDay, to: upcomingEnd)
            let (today, upcoming) = try await (todayEvents, upcomingEvents)
            if today.timedOut || upcoming.timedOut {
                section.warnings.append("calendar: fetch did not complete within 15s — section may be incomplete")
            }
            section.payload = DigestPayload.CalendarSection(today: today.results, upcoming: upcoming.results)
        } catch {
            section.warnings.append("calendar: \(error.localizedDescription)")
        }
        return section
    }

    private static func remindersSection(
        startOfDay: Date, endOfDay: Date
    ) async -> Section<DigestPayload.RemindersSection> {
        var section = Section(payload: DigestPayload.RemindersSection(dueToday: [], overdue: []))
        do {
            let bridge = RemindersBridge()
            let outcome = try await bridge.listReminders(completed: false, limit: 500)
            let allReminders = outcome.results
            if outcome.timedOut {
                section.warnings.append("reminders: fetch did not complete within 15s — section may be incomplete")
            }
            let dueToday = allReminders.filter { r in
                guard let due = r.dueDate, let date = parseCalendarDate(due) else { return false }
                return date >= startOfDay && date < endOfDay
            }
            let overdue = allReminders.filter { r in
                guard let due = r.dueDate, let date = parseCalendarDate(due) else { return false }
                return date < startOfDay
            }
            section.payload = DigestPayload.RemindersSection(dueToday: dueToday, overdue: overdue)
        } catch {
            section.warnings.append("reminders: \(error.localizedDescription)")
        }
        return section
    }

    private static func notesSection(limit: Int) async -> Section<DigestPayload.NotesSection> {
        var section = Section(payload: DigestPayload.NotesSection(recent: []))
        do {
            // listNotes spawns a blocking osascript subprocess; hop off the
            // cooperative pool so concurrent callers don't stall.
            let outcome = try await detachBlocking { try NotesBridge.listNotes(limit: limit) }
            if outcome.timedOut {
                section.warnings.append("notes: scan timed out — recent notes may be missing or unsorted")
            }
            section.payload = DigestPayload.NotesSection(recent: outcome.results.map { NoteDigestInfo(from: $0) })
        } catch {
            section.warnings.append("notes: \(error.localizedDescription)")
        }
        return section
    }
}
