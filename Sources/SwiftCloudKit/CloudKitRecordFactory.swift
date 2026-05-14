//
//  CloudKitRecordFactory.swift
//  Generic CloudKit Record Factory
//
//  Created for generic CloudKit integration across all projects
//  Reference: CLOUDKIT_STRUCTURE_FOR_OTHER_PROJECTS.md
//

import CloudKit
import Foundation

/// CloudKit record factory - handles model↔record conversions with proper naming conventions
public enum CloudKitRecordFactory {

    // MARK: - Record Types

    public enum RecordType {
        public static let userProfile = "UserProfile"
        public static let appData = "AppData"
        public static let settings = "Settings"
        // Add more record types as needed per project
    }

    // MARK: - Zone ID

    public static var zoneID: CKRecordZone.ID {
        return CloudKitManager.shared.zoneID
    }

    // MARK: - Record ID Generation

    /// Generate record ID for user profile (single record per user)
    public static func userProfileRecordID() -> CKRecord.ID {
        return CKRecord.ID(
            recordName: "userprofile_default",
            zoneID: zoneID
        )
    }

    /// Generate record ID for app data (single record per user)
    public static func appDataRecordID() -> CKRecord.ID {
        return CKRecord.ID(
            recordName: "appdata_default",
            zoneID: zoneID
        )
    }

    /// Generate record ID for settings (single record per user)
    public static func settingsRecordID() -> CKRecord.ID {
        return CKRecord.ID(
            recordName: "settings_default",
            zoneID: zoneID
        )
    }

    /// Generate record ID with custom name
    public static func customRecordID(name: String) -> CKRecord.ID {
        return CKRecord.ID(
            recordName: name,
            zoneID: zoneID
        )
    }

    // MARK: - Record Creation

    /// Create a user profile record
    public static func createUserProfile() -> CKRecord {
        let recordID = userProfileRecordID()
        let record = CKRecord(recordType: RecordType.userProfile, recordID: recordID)

        // Set default values
        record["created_at"] = Date()
        record["updated_at"] = Date()

        return record
    }

    /// Create an app data record
    public static func createAppData() -> CKRecord {
        let recordID = appDataRecordID()
        let record = CKRecord(recordType: RecordType.appData, recordID: recordID)

        // Set default values
        record["created_at"] = Date()
        record["updated_at"] = Date()

        return record
    }

    /// Create a settings record
    public static func createSettings() -> CKRecord {
        let recordID = settingsRecordID()
        let record = CKRecord(recordType: RecordType.settings, recordID: recordID)

        // Set default values
        record["created_at"] = Date()
        record["updated_at"] = Date()

        return record
    }

    // MARK: - Helper Methods

    /// Update timestamp fields on a record
    public static func updateTimestamps(_ record: CKRecord) {
        let now = Date()

        // Update "updated_at" if it exists
        if record["updated_at"] == nil {
            record["updated_at"] = now
        } else {
            record["updated_at"] = now
        }

        // Set "created_at" only if it doesn't exist
        if record["created_at"] == nil {
            record["created_at"] = now
        }
    }

    /// Create a CKAsset from data (with temp file registration)
    public static func createAsset(from data: Data) throws -> CKAsset {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString
        let fileURL = tempDir.appendingPathComponent(fileName)

        try data.write(to: fileURL)

        // Register temp file for cleanup
        CloudKitAssetCleanup.shared.registerTempFile(fileURL)

        return CKAsset(fileURL: fileURL)
    }

    /// Create a CKAsset from a URL (with temp file registration)
    public static func createAsset(from url: URL) throws -> CKAsset {
        // If it's already a temp file, just register it
        if url.path.contains(FMFileManager.default.temporaryDirectory.path) {
            CloudKitAssetCleanup.shared.registerTempFile(url)
            return CKAsset(fileURL: url)
        }

        // Otherwise, copy to temp directory
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString
        let tempURL = tempDir.appendingPathComponent(fileName)

        try FileManager.default.copyItem(at: url, to: tempURL)

        // Register temp file for cleanup
        CloudKitAssetCleanup.shared.registerTempFile(tempURL)

        return CKAsset(fileURL: tempURL)
    }

    /// Extract data from a CKAsset
    public static func data(from asset: CKAsset) throws -> Data {
        return try Data(contentsOf: asset.fileURL)
    }
}

// MARK: - FMFileManager Fix

private class FMFileManager {
    static let `default` = FileManager()
}
