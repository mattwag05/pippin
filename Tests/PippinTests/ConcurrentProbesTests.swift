import Foundation
@testable import PippinLib
import XCTest

/// A meeting point that only opens once `parties` callers are waiting at it
/// together. Probes run one after another never meet: each `arrive` then
/// returns false at its timeout, which is how these tests tell concurrent
/// work from serial work without measuring time.
final class Rendezvous: @unchecked Sendable {
    private let condition = NSCondition()
    private let parties: Int
    private var waiting = 0
    private var met = false

    init(parties: Int) {
        self.parties = parties
    }

    func arrive(timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        waiting += 1
        if waiting >= parties {
            met = true
            condition.broadcast()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !met {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}

/// `doctor` runs its probes at once (PERF-7) and still reports them in order.
final class DoctorConcurrencyTests: XCTestCase {
    func testProbesAreInFlightTogetherAndReportedInOrder() {
        let count = 6
        let rendezvous = Rendezvous(parties: count)
        let probes: [@Sendable () -> [DiagnosticCheck]] = (0 ..< count).map { i in
            {
                let met = rendezvous.arrive()
                return [DiagnosticCheck(name: "probe \(i)", status: met ? .ok : .fail, detail: "")]
            }
        }
        let checks = runChecksConcurrently(probes)
        XCTAssertEqual(checks.map(\.name), (0 ..< count).map { "probe \($0)" })
        XCTAssertTrue(checks.allSatisfy { $0.status == .ok }, "the probes never overlapped")
    }

    func testAProbeThatReturnsSeveralChecksKeepsThemTogether() {
        let checks = runChecksConcurrently([
            { [DiagnosticCheck(name: "a", status: .ok, detail: "")] },
            { [
                DiagnosticCheck(name: "b1", status: .ok, detail: ""),
                DiagnosticCheck(name: "b2", status: .skip, detail: ""),
            ] },
            { [] },
            { [DiagnosticCheck(name: "c", status: .ok, detail: "")] },
        ])
        XCTAssertEqual(checks.map(\.name), ["a", "b1", "b2", "c"])
    }

    func testTheRealCheckListKeepsItsDocumentedOrder() {
        let names = runAllChecks(config: nil).map(\.name)
        XCTAssertEqual(names.first, "macOS version")
        XCTAssertEqual(names.last, "Policy file")
        XCTAssertLessThan(
            try XCTUnwrap(names.firstIndex(of: "Mail automation")),
            try XCTUnwrap(names.firstIndex(of: "Notes automation"))
        )
    }
}

/// `digest` gathers its four sections at once (PERF-7) and keeps the warnings
/// in section order.
final class DigestConcurrencyTests: XCTestCase {
    private func sources(_ arrive: @escaping @Sendable () -> Bool) -> DigestCommand.Sources {
        @Sendable func warning(_ name: String) -> [String] {
            [arrive() ? "\(name): met" : "\(name): alone"]
        }
        return DigestCommand.Sources(
            mail: {
                .init(payload: .init(totalUnread: 4, perAccount: []), warnings: warning("mail"))
            },
            calendar: { .init(payload: .init(today: [], upcoming: []), warnings: warning("calendar")) },
            reminders: { .init(payload: .init(dueToday: [], overdue: []), warnings: warning("reminders")) },
            notes: { .init(payload: .init(recent: []), warnings: warning("notes")) }
        )
    }

    func testTheFourSectionsAreInFlightTogetherAndWarningsKeepSectionOrder() async {
        let rendezvous = Rendezvous(parties: 4)
        let payload = await DigestCommand.assemble(skipping: [], from: sources { rendezvous.arrive() })
        XCTAssertEqual(payload.warnings, ["mail: met", "calendar: met", "reminders: met", "notes: met"])
        XCTAssertEqual(payload.mail.totalUnread, 4)
    }

    func testASkippedSectionIsNeverAskedForAndStaysEmpty() async {
        let rendezvous = Rendezvous(parties: 2)
        let payload = await DigestCommand.assemble(
            skipping: ["mail", "notes"], from: sources { rendezvous.arrive() }
        )
        XCTAssertEqual(payload.warnings, ["calendar: met", "reminders: met"])
        XCTAssertEqual(payload.mail.totalUnread, 0)
    }
}

/// `status` asks Mail and Notes once each and shares the answers with the
/// permissions table (PERF-7), with the Apple Event probes in flight together.
final class StatusProbeTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ name: String) {
            lock.withLock { counts[name, default: 0] += 1 }
        }

        subscript(name: String) -> Int {
            lock.withLock { counts[name] ?? 0 }
        }
    }

    /// Probes that touch nothing on the machine. `rendezvous`, when given, is
    /// where the three Apple Event probes must meet.
    private func fakeProbes(
        calls: Calls, mailAccess: Bool = true, notesAccess: Bool = true, rendezvous: Rendezvous? = nil
    ) -> StatusProbes {
        var probes = StatusProbes()
        probes.mailAccounts = {
            calls.record("mailAccounts")
            guard rendezvous?.arrive() ?? true, mailAccess else { return nil }
            return [MailAccount(name: "Personal", email: "p@example.com")]
        }
        probes.mailboxCounts = { accounts in
            calls.record("mailboxCounts")
            return Dictionary(uniqueKeysWithValues: accounts.map { ($0.name, 7) })
        }
        probes.notesFolders = {
            calls.record("notesFolders")
            guard rendezvous?.arrive() ?? true, notesAccess else { return nil }
            return BridgeOutcome(results: [], timedOut: false)
        }
        probes.notesCount = {
            calls.record("notesCount")
            return (rendezvous?.arrive() ?? true) ? 42 : nil
        }
        probes.calendar = { nil }
        probes.reminders = { nil }
        probes.memos = { StatusReport.MemosStatus(recordingCount: 3) }
        probes.contacts = { nil }
        probes.memosReadable = { true }
        return probes
    }

    private func granted(_ report: StatusReport, _ name: String) -> Bool? {
        report.permissions.first { $0.name == name }?.granted
    }

    func testMailAndNotesAreEachProbedOnceAndFeedBothTheirSectionAndThePermissionsTable() {
        let calls = Calls()
        let report = buildStatusReport(budgetMs: 0, probes: fakeProbes(calls: calls))

        XCTAssertEqual(calls["mailAccounts"], 1)
        XCTAssertEqual(calls["notesFolders"], 1)
        XCTAssertEqual(calls["notesCount"], 1)
        XCTAssertEqual(calls["mailboxCounts"], 1)
        XCTAssertEqual(report.mail?.accounts.map(\.mailboxCount), [7])
        XCTAssertEqual(report.notes?.noteCount, 42)
        XCTAssertEqual(report.notes?.timedOut, false)
        XCTAssertEqual(report.memos?.recordingCount, 3)
        XCTAssertEqual(granted(report, "Mail"), true)
        XCTAssertEqual(granted(report, "Notes"), true)
        XCTAssertEqual(granted(report, "Voice Memos"), true)
        XCTAssertEqual(
            report.permissions.map(\.name), ["Mail", "Calendar", "Reminders", "Contacts", "Voice Memos", "Notes"]
        )
        XCTAssertFalse(report.timedOut)
    }

    func testNoAccessLeavesTheSectionNilAndThePermissionDenied() {
        let calls = Calls()
        let report = buildStatusReport(
            budgetMs: 0, probes: fakeProbes(calls: calls, mailAccess: false, notesAccess: false)
        )
        XCTAssertNil(report.mail)
        XCTAssertNil(report.notes)
        XCTAssertEqual(granted(report, "Mail"), false)
        XCTAssertEqual(granted(report, "Notes"), false)
        XCTAssertEqual(calls["mailboxCounts"], 0, "no accounts, so no count scan")
        XCTAssertFalse(report.timedOut)
    }

    func testAFailedNoteCountMarksTheNotesSectionPartial() {
        var probes = fakeProbes(calls: Calls())
        probes.notesCount = { nil }
        let notes = buildStatusReport(budgetMs: 0, probes: probes).notes
        XCTAssertEqual(notes?.noteCount, 0)
        XCTAssertEqual(notes?.timedOut, true)
    }

    func testTheAppleEventProbesAreInFlightTogether() {
        let report = buildStatusReport(
            budgetMs: 0, probes: fakeProbes(calls: Calls(), rendezvous: Rendezvous(parties: 3))
        )
        // Each probe reports "no access" unless all three met.
        XCTAssertNotNil(report.mail, "the probes never overlapped")
        XCTAssertEqual(report.notes?.noteCount, 42)
        XCTAssertEqual(report.notes?.timedOut, false)
    }

    /// Two connections opening the live Voice Memos database at once can fail
    /// one of them, which showed up as a missing section or a denied
    /// permission. The two memos probes must run one after the other.
    func testTheTwoVoiceMemosProbesNeverOverlap() {
        let calls = Calls()
        var probes = fakeProbes(calls: calls)
        probes.memos = {
            Thread.sleep(forTimeInterval: 0.05)
            calls.record("memosFinished")
            return StatusReport.MemosStatus(recordingCount: 3)
        }
        probes.memosReadable = { calls["memosFinished"] == 1 }
        let report = buildStatusReport(budgetMs: 0, probes: probes)
        XCTAssertEqual(granted(report, "Voice Memos"), true, "the readable probe started before the section finished")
    }

    func testAProbeThatMissesTheBudgetLeavesThePermissionsTableEmpty() {
        var probes = fakeProbes(calls: Calls())
        let release = DispatchSemaphore(value: 0)
        probes.notesFolders = {
            release.wait()
            return nil
        }
        let report = buildStatusReport(budgetMs: 50, probes: probes)
        release.signal()
        XCTAssertTrue(report.timedOut)
        XCTAssertNil(report.notes)
        XCTAssertNotNil(report.mail)
        XCTAssertTrue(report.permissions.isEmpty)
    }
}
