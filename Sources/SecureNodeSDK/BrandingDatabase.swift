import Foundation
import SQLite3

/**
 * Local SQLite database for branding cache
 */
class BrandingDatabase {
    private var db: OpaquePointer?
    private let dbPath: String
    
    init() {
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dbPath = documentsPath.appendingPathComponent("securenode_branding.db").path
        
        openDatabase()
        createTable()
    }
    
    deinit {
        closeDatabase()
    }
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Error opening database")
        }
    }
    
    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    private func createTable() {
        let createTableSQL = """
            CREATE TABLE IF NOT EXISTS branding (
                phone_number_e164 TEXT PRIMARY KEY,
                brand_name TEXT NOT NULL,
                logo_url TEXT,
                call_reason TEXT,
                updated_at INTEGER NOT NULL
            );
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableSQL, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error creating table")
            }
        }
        sqlite3_finalize(statement)
    }
    
    /**
     * Get branding for a phone number
     */
    func getBranding(for phoneNumber: String) -> BrandingInfo? {
        let querySQL = "SELECT phone_number_e164, brand_name, logo_url, call_reason, updated_at FROM branding WHERE phone_number_e164 = ? LIMIT 1;"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        
        sqlite3_bind_text(statement, 1, phoneNumber, -1, nil)
        
        var branding: BrandingInfo? = nil
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let e164 = String(cString: sqlite3_column_text(statement, 0))
            let brandName = String(cString: sqlite3_column_text(statement, 1))
            let logoUrl = sqlite3_column_text(statement, 2) != nil ? String(cString: sqlite3_column_text(statement, 2)) : nil
            let callReason = sqlite3_column_text(statement, 3) != nil ? String(cString: sqlite3_column_text(statement, 3)) : nil
            let updatedAt = sqlite3_column_int64(statement, 4)
            
            let dateFormatter = ISO8601DateFormatter()
            let date = Date(timeIntervalSince1970: TimeInterval(updatedAt))
            let updatedAtString = dateFormatter.string(from: date)
            
            branding = BrandingInfo(
                phoneNumberE164: e164,
                brandName: brandName,
                logoUrl: logoUrl,
                callReason: callReason,
                updatedAt: updatedAtString
            )
        }
        
        sqlite3_finalize(statement)
        return branding
    }
    
    /**
     * Save branding records
     */
    func saveBranding(_ brandingList: [BrandingInfo]) {
        let insertSQL = "INSERT OR REPLACE INTO branding (phone_number_e164, brand_name, logo_url, call_reason, updated_at) VALUES (?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        
        for branding in brandingList {
            sqlite3_bind_text(statement, 1, branding.phoneNumberE164, -1, nil)
            sqlite3_bind_text(statement, 2, branding.brandName ?? "", -1, nil)
            sqlite3_bind_text(statement, 3, branding.logoUrl, -1, nil)
            sqlite3_bind_text(statement, 4, branding.callReason, -1, nil)
            sqlite3_bind_int64(statement, 5, Int64(Date().timeIntervalSince1970))
            
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error inserting branding")
            }
            
            sqlite3_reset(statement)
        }
        
        sqlite3_finalize(statement)
    }
    
    /**
     * Delete old branding records
     */
    func deleteOldBranding(before date: Date) {
        let cutoffTimestamp = Int64(date.timeIntervalSince1970)
        let deleteSQL = "DELETE FROM branding WHERE updated_at < ?;"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        
        sqlite3_bind_int64(statement, 1, cutoffTimestamp)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            print("Error deleting old branding")
        }
        
        sqlite3_finalize(statement)
    }
}

