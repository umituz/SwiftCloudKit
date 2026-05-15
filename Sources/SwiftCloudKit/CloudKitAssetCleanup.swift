//
//  CloudKitAssetCleanup.swift
//  SwiftCloudKit
//
//  Manages temp file lifecycle for CKAsset operations.
//

import CloudKit
import Foundation
import os.log

/// CloudKit asset cleanup — manages temp file lifecycle for CKAsset operations.
///
/// Tracks temp files created by ``CloudKitRecordFactory`` asset helpers and cleans them up
/// when they are no longer needed. Also cleans stale temp files from previous sessions on init.
@MainActor
public final class CloudKitAssetCleanup {

    // MARK: - Singleton

    public static let shared = CloudKitAssetCleanup()

    // MARK: - Properties

    private var tempFiles: Set<URL> = []
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "SwiftCloudKit", category: "AssetCleanup")

    /// Prefix used to tag temp files created by SwiftCloudKit.
    static let filePrefix = "sck_temp_"

    // MARK: - Initialization

    private init() {
        self.fileManager = .default
        cleanStaleTempFiles()
    }

    // MARK: - Public Methods

    /// Register a temp file for tracking.
    public func registerTempFile(_ url: URL) {
        tempFiles.insert(url)
    }

    /// Register multiple temp files for tracking.
    public func registerTempFiles(_ urls: [URL]) {
        tempFiles.formUnion(urls)
    }

    /// Cleanup temp files whose filename contains the given identifier.
    public func cleanupTempFiles(for identifier: String) {
        let filesToRemove = tempFiles.filter { $0.lastPathComponent.contains(identifier) }
        for fileURL in filesToRemove {
            removeTempFile(fileURL)
        }
        tempFiles.subtract(filesToRemove)
    }

    /// Cleanup assets for a specific record.
    public func cleanup(record: CKRecord) {
        for key in record.allKeys() {
            if let asset = record[key] as? CKAsset,
               let fileURL = asset.fileURL {
                removeTempFile(fileURL)
                tempFiles.remove(fileURL)
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

    // MARK: - Debug

    /// Number of currently tracked temp files.
    public var tempFileCount: Int {
        return tempFiles.count
    }

    // MARK: - Private Methods

    private func removeTempFile(_ url: URL) {
        do {
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        } catch {
            logger.warning("Failed to remove temp file \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Clean up orphaned SwiftCloudKit temp files from previous app sessions.
    private func cleanStaleTempFiles() {
        let tempDir = fileManager.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        let now = Date()
        let staleAge: TimeInterval = 3600 // 1 hour

        for fileURL in contents {
            guard fileURL.lastPathComponent.hasPrefix(Self.filePrefix) else { continue }

            if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = attrs.contentModificationDate,
               now.timeIntervalSince(modDate) > staleAge {
                removeTempFile(fileURL)
            }
        }
    }
}
