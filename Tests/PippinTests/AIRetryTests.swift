@testable import PippinLib
import XCTest

/// Tests for the transient-failure retry policy shared by all AI providers
/// (`withAIRetry` / `isTransientAIError` in AIProvider.swift). The policy is
/// exercised with an injectable clock + no-op sleep, so no network or real
/// wall-clock delay is involved. (pippin-cfg)
final class AIRetryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0)

    // MARK: - Error classification

    func testTransientClassification() {
        XCTAssertTrue(isTransientAIError(.apiError(429, "rate limited")))
        XCTAssertTrue(isTransientAIError(.apiError(500, "boom")))
        XCTAssertTrue(isTransientAIError(.apiError(503, "overloaded")))
        XCTAssertTrue(isTransientAIError(.apiError(529, "overloaded")))
        XCTAssertTrue(isTransientAIError(.networkError("connection reset")))

        XCTAssertFalse(isTransientAIError(.apiError(400, "bad request")))
        XCTAssertFalse(isTransientAIError(.apiError(401, "unauthorized")))
        XCTAssertFalse(isTransientAIError(.apiError(404, "not found")))
        XCTAssertFalse(isTransientAIError(.timeout), "a timeout already consumed the budget")
        XCTAssertFalse(isTransientAIError(.providerUnreachable("down")))
        XCTAssertFalse(isTransientAIError(.decodingFailed("garbage")))
        XCTAssertFalse(isTransientAIError(.missingAPIKey))
    }

    // MARK: - Retry policy

    func testSucceedsFirstTryNoRetry() throws {
        var attempts = 0
        var slept: [TimeInterval] = []
        let result = try withAIRetry(totalBudget: 50, now: { self.epoch }, sleep: { slept.append($0) }) { _ in
            attempts += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(slept.isEmpty, "no backoff when the first attempt succeeds")
    }

    func testRetriesTransientThenSucceeds() throws {
        var attempts = 0
        var slept: [TimeInterval] = []
        let result = try withAIRetry(totalBudget: 50, now: { self.epoch }, sleep: { slept.append($0) }) { _ in
            attempts += 1
            if attempts == 1 { throw AIProviderError.apiError(503, "overloaded") }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(slept.count, 1, "one backoff between the failed and successful attempt")
    }

    func testGivesUpAfterMaxRetries() {
        var attempts = 0
        XCTAssertThrowsError(
            try withAIRetry(totalBudget: 50, maxRetries: 2, now: { self.epoch }, sleep: { _ in }) { _ in
                attempts += 1
                throw AIProviderError.apiError(503, "overloaded")
            }
        ) { error in
            guard case let AIProviderError.apiError(code, _) = error else {
                return XCTFail("expected the last transient error, got \(error)")
            }
            XCTAssertEqual(code, 503)
        }
        XCTAssertEqual(attempts, 3, "initial try + 2 retries")
    }

    func testNonTransientThrowsImmediately() {
        var attempts = 0
        XCTAssertThrowsError(
            try withAIRetry(totalBudget: 50, now: { self.epoch }, sleep: { _ in }) { _ in
                attempts += 1
                throw AIProviderError.apiError(400, "bad request")
            }
        )
        XCTAssertEqual(attempts, 1, "a 400 is not retried")
    }

    func testStopsWhenBudgetExhausted() {
        var clock = epoch
        var attempts = 0
        XCTAssertThrowsError(
            try withAIRetry(
                totalBudget: 50, maxRetries: 2, minAttemptSeconds: 5,
                now: { clock }, sleep: { _ in }
            ) { _ in
                attempts += 1
                clock = clock.addingTimeInterval(48) // leaves 2s < minAttempt
                throw AIProviderError.apiError(503, "overloaded")
            }
        )
        XCTAssertEqual(attempts, 1, "no second attempt once the budget can't fit one")
    }

    func testAttemptTimeoutShrinksWithRemainingBudget() throws {
        var clock = epoch
        var attempts = 0
        var timeouts: [TimeInterval] = []
        let result = try withAIRetry(
            totalBudget: 50, now: { clock }, sleep: { _ in }
        ) { attemptTimeout in
            timeouts.append(attemptTimeout)
            attempts += 1
            clock = clock.addingTimeInterval(10) // 10s elapses per attempt
            if attempts < 2 { throw AIProviderError.networkError("blip") }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(timeouts, [50, 40], "each attempt gets the remaining budget as its timeout")
    }
}
