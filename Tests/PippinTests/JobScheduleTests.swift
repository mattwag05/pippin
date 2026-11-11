import Foundation
@testable import PippinLib
import XCTest

final class JobScheduleTests: XCTestCase {
    private var dir: String!
    private var store: JobStore!
    private var calls: Calls!

    final class Calls: @unchecked Sendable {
        var list: [[String]] = []
        var status: Int32 = 0
    }

    override func setUp() {
        super.setUp()
        let base = NSTemporaryDirectory() + "pippin-sched-\(UUID().uuidString)"
        dir = base + "/LaunchAgents"
        store = JobStore(root: base + "/jobs")
        calls = Calls()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent)
        super.tearDown()
    }

    private func scheduleStore() -> ScheduleStore {
        let calls = calls!
        return ScheduleStore(
            directory: dir,
            launchctl: Launchctl { args in
                calls.list.append(args)
                return (calls.status, calls.status == 0 ? "" : "boom")
            },
            uid: 501
        )
    }

    private func readPlist(_ id: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: scheduleStore().plistPath(id)))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    // MARK: Cron and interval parsing

    func testEveryParses() throws {
        XCTAssertEqual(try ScheduleTrigger.parseEvery("15m"), .every(seconds: 900))
        XCTAssertEqual(try ScheduleTrigger.parseEvery("6h"), .every(seconds: 21600))
        XCTAssertEqual(try ScheduleTrigger.parseEvery("1d").description, "every 1d")
        XCTAssertThrowsError(try ScheduleTrigger.parseEvery("30s"))
        XCTAssertThrowsError(try ScheduleTrigger.parseEvery("soon"))
    }

    func testCronTranslatesNumbersStarsAndLists() throws {
        guard case let .cron(_, dicts) = try ScheduleTrigger.parseCron("30 7 * * 1,2") else { return XCTFail() }
        XCTAssertEqual(dicts.count, 2)
        XCTAssertTrue(dicts.contains(["Minute": 30, "Hour": 7, "Weekday": 1]))
        XCTAssertTrue(dicts.contains(["Minute": 30, "Hour": 7, "Weekday": 2]))
        guard case let .cron(_, all) = try ScheduleTrigger.parseCron("* * * * *") else { return XCTFail() }
        XCTAssertEqual(all, [[:]])
    }

    func testCronRejectsRangesStepsAndBadFields() {
        for bad in ["*/5 * * * *", "0 9-17 * * *", "0 9 * * 1-5", "60 * * * *", "0 24 * * *", "0 0 0 * *", "0 0 * 13 *", "0 0 * * 8", "0 0 * *", "a * * * *", "0, * * * *"] {
            XCTAssertThrowsError(try ScheduleTrigger.parseCron(bad), bad)
        }
    }

    // MARK: Plist generation

    func testEveryPlist() throws {
        let id = try scheduleStore().add(trigger: .every(seconds: 900), argv: ["mail", "index"], pippinPath: "/x/pippin")
        let plist = try readPlist(id)
        XCTAssertEqual(plist["Label"] as? String, "com.mattwag05.pippin.schedule.\(id)")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/x/pippin", "job", "run", "--wait", "--schedule-id", id, "--", "mail", "index"])
        XCTAssertEqual(plist["StartInterval"] as? Int, 900)
        XCTAssertNil(plist["StartCalendarInterval"])
        let mode = try FileManager.default.attributesOfItem(atPath: scheduleStore().plistPath(id))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testCronPlist() throws {
        let trigger = try ScheduleTrigger.parseCron("0,30 9 * * *")
        let id = try scheduleStore().add(trigger: trigger, argv: ["digest"], pippinPath: "/x/pippin")
        let plist = try readPlist(id)
        let intervals = try XCTUnwrap(plist["StartCalendarInterval"] as? [[String: Int]])
        XCTAssertEqual(intervals.count, 2)
        XCTAssertTrue(intervals.contains(["Minute": 0, "Hour": 9]))
        XCTAssertTrue(intervals.contains(["Minute": 30, "Hour": 9]))
        XCTAssertNil(plist["StartInterval"])
    }

    // MARK: Round trip

    func testScheduleListUnscheduleRoundTrip() throws {
        let s = scheduleStore()
        let id = try s.add(trigger: .every(seconds: 3600), argv: ["mail", "index"], pippinPath: "/x/pippin")
        XCTAssertEqual(calls.list, [["bootstrap", "gui/501", s.plistPath(id)]])

        let past = Date(timeIntervalSinceNow: -100)
        try store.createDir("aaaa")
        try store.write(Job(id: "aaaa", argv: ["mail", "index"], status: .done, startedAt: past, endedAt: Date(), scheduleId: id))
        let listed = s.list(jobs: store.all())
        XCTAssertEqual(listed.map(\.id), [id])
        XCTAssertEqual(listed.first?.argv, ["mail", "index"])
        XCTAssertEqual(listed.first?.trigger, "every 1h")
        XCTAssertEqual(listed.first?.lastStatus, .done)

        try s.remove(id)
        XCTAssertEqual(calls.list.last, ["bootout", "gui/501/com.mattwag05.pippin.schedule.\(id)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.plistPath(id)))
        XCTAssertTrue(s.list(jobs: []).isEmpty)
        XCTAssertThrowsError(try s.remove(id))
    }

    func testBootstrapFailureLeavesNoPlist() {
        calls.status = 5
        XCTAssertThrowsError(try scheduleStore().add(trigger: .every(seconds: 60), argv: ["status"], pippinPath: "/x/pippin"))
        XCTAssertTrue(scheduleStore().list(jobs: []).isEmpty)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir))?.count, 0)
    }

    func testListIgnoresForeignPlists() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/com.other.thing.plist"))
        XCTAssertTrue(scheduleStore().list(jobs: []).isEmpty)
    }

    // MARK: Overlap

    func testOverlapIsSkippedAndRecorded() throws {
        let started = try XCTUnwrap(ProcessTable.startTime(of: getpid()))
        try store.createDir("run1")
        try store.write(Job(id: "run1", argv: ["x"], pid: getpid(), status: .running, startedAt: started, scheduleId: "sch"))

        let skipped = try XCTUnwrap(store.skipIfOverlapping(scheduleId: "sch", id: "run2", argv: ["x"]))
        XCTAssertEqual(skipped.status, .skipped)
        XCTAssertEqual(skipped.errorCode, "overlap")
        XCTAssertEqual(try store.read("run2").status, .skipped)
        XCTAssertEqual(try store.read("run1").status, .running)
        // A different schedule is unaffected.
        XCTAssertNil(try store.skipIfOverlapping(scheduleId: "other", id: "run3", argv: ["x"]))
    }

    func testDeadRunnerDoesNotBlockNextFire() throws {
        try store.createDir("run1")
        try store.write(Job(id: "run1", argv: ["x"], pid: 999_999, status: .running, startedAt: Date(timeIntervalSinceNow: -3600), scheduleId: "sch"))
        XCTAssertNil(try store.skipIfOverlapping(scheduleId: "sch", id: "run2", argv: ["x"]))
    }

    // MARK: Honest terminal status

    func testSignalDeathRecordsKilledNotDone() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "kill -9 $$"]
        try process.run()
        process.waitUntilExit()
        var job = Job(id: "k", argv: ["x"])
        job.finish(exitStatus: process.terminationStatus, reason: process.terminationReason)
        XCTAssertEqual(job.status, .killed)
        XCTAssertEqual(job.exitCode, 9)
    }

    func testExitCodesMapToDoneAndError() {
        var ok = Job(id: "a", argv: ["x"])
        ok.finish(exitStatus: 0, reason: .exit)
        XCTAssertEqual(ok.status, .done)
        var bad = Job(id: "b", argv: ["x"])
        bad.finish(exitStatus: 7, reason: .exit)
        XCTAssertEqual(bad.status, .error)
    }
}
