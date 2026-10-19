@testable import PippinLib
import XCTest

final class AsyncBridgeTests: XCTestCase {
    /// More concurrent callers than cooperative threads. Each hops with
    /// `runOffPool` before blocking in `waitForAsync`; without the hop every
    /// pool thread blocks and no async body can run (0 of 36 completed on an
    /// M5 before the hop was added, pippin-edjh).
    func testWaitForAsyncSurvivesMoreCallersThanPoolThreads() async {
        let callers = ProcessInfo.processInfo.activeProcessorCount * 2
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< callers {
                group.addTask {
                    let value = try? await runOffPool {
                        try waitForAsync(timeoutSeconds: 5) {
                            try await Task.sleep(nanoseconds: 50_000_000)
                            return 1
                        }
                    }
                    return value == 1
                }
            }
            var ok = 0
            for await success in group where success {
                ok += 1
            }
            return ok
        }
        XCTAssertEqual(results, callers)
    }

    func testWaitForAsyncPropagatesErrors() {
        struct Boom: Error {}
        XCTAssertThrowsError(try waitForAsync(timeoutSeconds: 5) { () async throws -> Int in throw Boom() }) { error in
            XCTAssertTrue(error is Boom)
        }
    }
}
