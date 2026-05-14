//
//  CloudKitAssetCleanup.swift
//  SwiftCloudKit
//
//  Manages temp file lifecycle for CKAsset operations.
//

import CloudKit
import Foundation

/// CloudKit asset cleanup - manages temp file lifecycle for CKAsset operations.
@MainActor
public final class CloudKitAssetCleanup {

    // MARK: - Singleton

    public static let shared = CloudKitAssetCleanup()

    // MARK: - Properties

    private var tempFiles: [URL] = []
    private let fileManager: FileManager

    // MARK: - Initialization

    private init() {
        self.fileManager = .default
    }

    // MARK: - Public Methods

    /// Register a temp file for tracking.
    public func registerTempFile(_ url: URL) {
        tempFiles.append(url)
    }

    /// Register multiple temp files for tracking.
    public func registerTempFiles(_ urls: [URL]) {
        tempFiles.append(contentsOf: urls)
    }

    /// Cleanup temp files matching a specific identifier.
    public func cleanupTempFiles(for identifier: String) {
        let filesToRemove = tempFiles.filter { $0.path.contains(identifier) }
        for fileURL in filesToRemove {
            removeTempFile(fileURL)
        }
        tempFiles.removeAll { $0.path.contains(identifier) }
    }

    /// Cleanup assets for a specific record.
    public func cleanup(record: CKRecord) {
        for key in record.allKeys() {
            if let asset = record[key] as? CKAsset,
               let fileURL = asset.fileURL {
                removeTempFile(fileURL)
            }
        }
    }

    /// Cleanup all tracked temp files.
    public func cleanupAll() {
        for fileURL in tempFiles {
            removeTempFile(fileURL)
        }
        tempFiles.removeAll()
    }

    // MARK: - Private Methods

    private func removeTempFile(_ url: URL) {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            print("[SwiftCloudKit] Failed to remove temp file: \(url.lastPathComponent), error: \(error)")
        }
    }

    // MARK: - Debug

    /// Number of tracked temp files.
    public var tempFileCount: Int {
        return tempFiles.count
    }
}
