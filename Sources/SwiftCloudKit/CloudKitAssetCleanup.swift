//
//  CloudKitAssetCleanup.swift
//  Generic CloudKit Asset Cleanup
//
//  Created for generic CloudKit integration across all projects
//  Reference: CLOUDKIT_STRUCTURE_FOR_OTHER_PROJECTS.md
//

import CloudKit
import Foundation

/// CloudKit asset cleanup - manages temp file lifecycle for CKAsset operations
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

    /// Register a temp file for tracking
    public func registerTempFile(_ url: URL) {
        tempFiles.append(url)
    }

    /// Register multiple temp files for tracking
    public func registerTempFiles(_ urls: [URL]) {
        tempFiles.append(contentsOf: urls)
    }

    /// Cleanup temp files for a specific project ID
    public func cleanupTempFiles(for projectID: UUID) {
        let prefix = projectID.uuidString
        let filesToRemove = tempFiles.filter { $0.path.contains(prefix) }

        for fileURL in filesToRemove {
            removeTempFile(fileURL)
        }

        tempFiles.removeAll { $0.path.contains(prefix) }
    }

    /// Cleanup temp files for a specific identifier
    public func cleanupTempFiles(for identifier: String) {
        let filesToRemove = tempFiles.filter { $0.path.contains(identifier) }

        for fileURL in filesToRemove {
            removeTempFile(fileURL)
        }

        tempFiles.removeAll { $0.path.contains(identifier) }
    }

    /// Cleanup assets for a specific record
    public func cleanup(record: CKRecord) {
        for (key, value) in record.allKeys() {
            if let asset = value as? CKAsset {
                removeTempFile(asset.fileURL)
            }
        }
    }

    /// Cleanup all temp files
    public func cleanupAll() {
        for fileURL in tempFiles {
            removeTempFile(fileURL)
        }

        tempFiles.removeAll()
    }

    /// Emergency cleanup - remove all temp files in system temp directory
    public func emergencyCleanup() {
        let tempDir = fileManager.temporaryDirectory

        guard let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: nil) else {
            return
        }

        for case let fileURL as URL in enumerator {
            // Only remove files that we created (based on UUID naming pattern)
            if fileURL.lastComponent.count == 36 && fileURL.lastComponent.contains("-") {
                try? fileManager.removeItem(at: fileURL)
            }
        }

        tempFiles.removeAll()
    }

    // MARK: - Private Methods

    private func removeTempFile(_ url: URL) {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            print("Failed to remove temp file: \(url.path), error: \(error)")
        }
    }

    // MARK: - Debug Information

    /// Get count of tracked temp files
    public var tempFileCount: Int {
        return tempFiles.count
    }

    /// Get total size of tracked temp files
    public var tempFileSize: Int64 {
        var totalSize: Int64 = 0

        for fileURL in tempFiles {
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }

        return totalSize
    }

    /// Get total size formatted as string
    public var tempFileSizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: tempFileSize)
    }

    /// Print debug information
    public func printDebugInfo() {
        print("=== CloudKit Asset Cleanup Debug Info ===")
        print("Temp files tracked: \(tempFileCount)")
        print("Total size: \(tempFileSizeFormatted)")
        print("Files:")
        for fileURL in tempFiles {
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? Int64 {
                let formatter = ByteCountFormatter()
                let sizeString = formatter.string(fromByteCount: fileSize)
                print("  - \(fileURL.lastComponent): \(sizeString)")
            }
        }
        print("=========================================")
    }
}
