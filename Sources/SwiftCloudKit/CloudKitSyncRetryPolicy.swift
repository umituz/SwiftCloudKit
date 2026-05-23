import CloudKit
import Foundation
import os.log

/// Retry policy for transient CloudKit errors with configurable exponential backoff.
@MainActor
struct CloudKitSyncRetryPolicy {

    let maxRetryCount: Int
    let baseDelay: TimeInterval
    /// Maximum delay cap between retries (seconds).
    static let maxRetryDelay: TimeInterval = 30.0
    let logger = Logger(subsystem: "SwiftCloudKit", category: "Retry")

    /// Determine whether a CKError is retryable.
    func isRetryable(_ error: CKError) -> Bool {
        switch error.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .partialFailure:
            return true
        default:
            if let retryAfter = error.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
                return retryAfter > 0
            }
            return false
        }
    }

    /// Execute an async operation with exponential backoff retry.
    /// Throws the last encountered error if all retries are exhausted.
    /// Executes at least once regardless of `maxRetryCount`.
    func executeWithRetry(_ operation: () async throws -> Void) async throws {
        var lastError: Error?
        let effectiveAttempts = max(1, maxRetryCount)

        for attempt in 0..<effectiveAttempts {
            do {
                try await operation()
                return
            } catch let error as CKError where isRetryable(error) {
                lastError = error
                if attempt < maxRetryCount - 1 {
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    let capped = min(delay, Self.maxRetryDelay)
                    logger.warning("Retry \(attempt + 1)/\(maxRetryCount) in \(capped)s")
                    try await Task.sleep(for: .seconds(capped))
                }
            } catch {
                // Non-retryable error — throw immediately
                throw error
            }
        }

        // All retries exhausted — throw the last error
        if let error = lastError {
            throw error
        }
    }
}
