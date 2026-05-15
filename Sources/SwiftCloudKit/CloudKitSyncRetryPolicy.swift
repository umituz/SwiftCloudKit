//
//  CloudKitSyncRetryPolicy.swift
//  SwiftCloudKit
//
//  Retry logic for transient CloudKit failures with exponential backoff.
//

import CloudKit
import Foundation
import os.log

/// Retry policy for transient CloudKit errors with configurable exponential backoff.
@MainActor
struct CloudKitSyncRetryPolicy {

    let maxRetryCount: Int
    let baseDelay: TimeInterval
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
    func executeWithRetry(_ operation: () async throws -> Void) async throws {
        for attempt in 0..<maxRetryCount {
            do {
                try await operation()
                return
            } catch let error as CKError where isRetryable(error) && attempt < maxRetryCount - 1 {
                let delay = baseDelay * pow(2.0, Double(attempt))
                let capped = min(delay, 30.0)
                logger.warning(
                    "Retry \(attempt + 1)/\(maxRetryCount) in \(capped)s"
                )
                try await Task.sleep(for: .seconds(capped))
            }
        }
    }
}
