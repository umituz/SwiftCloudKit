import CloudKit
import XCTest
@testable import SwiftCloudKit

@MainActor
final class RetryPolicyTests: XCTestCase {

    func testRetryableErrors() {
        let policy = CloudKitSyncRetryPolicy(maxRetryCount: 3, baseDelay: 1.0)

        let retryableCodes: [CKError.Code] = [
            .networkFailure,
            .networkUnavailable,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy,
            .partialFailure
        ]

        for code in retryableCodes {
            let error = CKError(code)
            XCTAssertTrue(policy.isRetryable(error), "Expected \(code) to be retryable")
        }
    }

    func testNonRetryableErrors() {
        let policy = CloudKitSyncRetryPolicy(maxRetryCount: 3, baseDelay: 1.0)
        let error = CKError(.notAuthenticated)
        XCTAssertFalse(policy.isRetryable(error))
    }

    func testExecuteWithRetrySucceedsOnFirstTry() async throws {
        let policy = CloudKitSyncRetryPolicy(maxRetryCount: 3, baseDelay: 0.01)
        var callCount = 0
        try await policy.executeWithRetry {
            callCount += 1
        }
        XCTAssertEqual(callCount, 1)
    }

    func testExecuteWithRetryThrowsNonRetryable() async {
        let policy = CloudKitSyncRetryPolicy(maxRetryCount: 3, baseDelay: 0.01)
        do {
            try await policy.executeWithRetry {
                throw CKError(.notAuthenticated)
            }
            XCTFail("Expected error")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .notAuthenticated)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
