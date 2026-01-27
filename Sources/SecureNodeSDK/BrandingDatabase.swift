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
        let createBrandingTableSQL = """
            CREATE TABLE IF NOT EXISTS branding (
                phone_number_e164 TEXT PRIMARY KEY,
                brand_name TEXT NOT NULL,
                logo_url TEXT,
                call_reason TEXT,
                brand_id TEXT,
                updated_at INTEGER NOT NULL
            );
        """

        let createPendingEventsSQL = """
            CREATE TABLE IF NOT EXISTS pending_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                phone_number_e164 TEXT NOT NULL,
                outcome TEXT NOT NULL,
                surface TEXT,
                displayed_at TEXT NOT NULL,
                event_key TEXT,
                meta_json TEXT,
                created_at INTEGER NOT NULL
            );
        """

        let createPendingTelemetrySQL = """
            CREATE TABLE IF NOT EXISTS pending_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                level TEXT NOT NULL,
                message TEXT NOT NULL,
                meta_json TEXT,
                occurred_at TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, createBrandingTableSQL, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error creating table")
            }
        }
        sqlite3_finalize(statement)

        // Best-effort: add brand_id column for existing installs (ignore errors).
        var alterStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "ALTER TABLE branding ADD COLUMN brand_id TEXT;", -1, &alterStmt, nil) == SQLITE_OK {
            _ = sqlite3_step(alterStmt)
        }
        sqlite3_finalize(alterStmt)

        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, createPendingEventsSQL, -1, &stmt2, nil) == SQLITE_OK {
            _ = sqlite3_step(stmt2)
        }
        sqlite3_finalize(stmt2)

        // Best-effort: add event_key/meta_json for existing installs (ignore errors).
        var alterEventsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "ALTER TABLE pending_events ADD COLUMN event_key TEXT;", -1, &alterEventsStmt, nil) == SQLITE_OK {
            _ = sqlite3_step(alterEventsStmt)
        }
        sqlite3_finalize(alterEventsStmt)

        var alterEventsStmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "ALTER TABLE pending_events ADD COLUMN meta_json TEXT;", -1, &alterEventsStmt2, nil) == SQLITE_OK {
            _ = sqlite3_step(alterEventsStmt2)
        }
        sqlite3_finalize(alterEventsStmt2)

        var stmt3: OpaquePointer?
        if sqlite3_prepare_v2(db, createPendingTelemetrySQL, -1, &stmt3, nil) == SQLITE_OK {
            _ = sqlite3_step(stmt3)
        }
        sqlite3_finalize(stmt3)

        // Helpful index for pruning/ordering
        var idxStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "CREATE INDEX IF NOT EXISTS idx_pending_events_created_at ON pending_events(created_at);", -1, &idxStmt, nil) == SQLITE_OK {
            _ = sqlite3_step(idxStmt)
        }
        sqlite3_finalize(idxStmt)

        var idxStmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "CREATE INDEX IF NOT EXISTS idx_pending_telemetry_created_at ON pending_telemetry(created_at);", -1, &idxStmt2, nil) == SQLITE_OK {
            _ = sqlite3_step(idxStmt2)
        }
        sqlite3_finalize(idxStmt2)
    }
    
    /**
     * Get branding for a phone number
     */
    func getBranding(for phoneNumber: String) -> BrandingInfo? {
        let querySQL = "SELECT phone_number_e164, brand_name, logo_url, call_reason, brand_id, updated_at FROM branding WHERE phone_number_e164 = ? LIMIT 1;"
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
            let brandId = sqlite3_column_text(statement, 4) != nil ? String(cString: sqlite3_column_text(statement, 4)) : nil
            let updatedAt = sqlite3_column_int64(statement, 5)
            
            let dateFormatter = ISO8601DateFormatter()
            let date = Date(timeIntervalSince1970: TimeInterval(updatedAt))
            let updatedAtString = dateFormatter.string(from: date)
            
            branding = BrandingInfo(
                phoneNumberE164: e164,
                brandName: brandName,
                logoUrl: logoUrl,
                callReason: callReason,
                brandId: brandId,
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
        let insertSQL = "INSERT OR REPLACE INTO branding (phone_number_e164, brand_name, logo_url, call_reason, brand_id, updated_at) VALUES (?, ?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        
        for branding in brandingList {
            sqlite3_bind_text(statement, 1, branding.phoneNumberE164, -1, nil)
            sqlite3_bind_text(statement, 2, branding.brandName ?? "", -1, nil)
            sqlite3_bind_text(statement, 3, branding.logoUrl, -1, nil)
            sqlite3_bind_text(statement, 4, branding.callReason, -1, nil)
            sqlite3_bind_text(statement, 5, branding.brandId, -1, nil)
            sqlite3_bind_int64(statement, 6, Int64(Date().timeIntervalSince1970))
            
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error inserting branding")
            }
            
            sqlite3_reset(statement)
        }
        
        sqlite3_finalize(statement)
    }

    /**
     * Replace local branding cache with the server-authoritative list.
     * This is used when syncing with `since == nil` so removals (paused/deleted) are reflected immediately.
     */
    func replaceAllBranding(_ brandingList: [BrandingInfo]) {
        // Clear existing
        var deleteStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM branding;", -1, &deleteStmt, nil) == SQLITE_OK {
            _ = sqlite3_step(deleteStmt)
        }
        sqlite3_finalize(deleteStmt)

        // Insert new
        saveBranding(brandingList)
    }

    struct PendingEventRow {
        let id: Int64
        let phoneNumberE164: String
        let outcome: String
        let surface: String?
        let displayedAt: String
        let eventKey: String?
        let metaJson: String?
        let createdAt: Int64
    }

    func insertPendingEvent(
        phoneNumberE164: String,
        outcome: String,
        surface: String?,
        displayedAt: String,
        eventKey: String?,
        metaJson: String?
    ) {
        let sql = "INSERT INTO pending_events (phone_number_e164, outcome, surface, displayed_at, event_key, meta_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }

        sqlite3_bind_text(statement, 1, phoneNumberE164, -1, nil)
        sqlite3_bind_text(statement, 2, outcome, -1, nil)
        if let surface = surface {
            sqlite3_bind_text(statement, 3, surface, -1, nil)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, displayedAt, -1, nil)
        if let eventKey = eventKey {
            sqlite3_bind_text(statement, 5, eventKey, -1, nil)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        if let metaJson = metaJson {
            sqlite3_bind_text(statement, 6, metaJson, -1, nil)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_int64(statement, 7, Int64(Date().timeIntervalSince1970))

        _ = sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func listPendingEvents(limit: Int) -> [PendingEventRow] {
        let sql = "SELECT id, phone_number_e164, outcome, surface, displayed_at, event_key, meta_json, created_at FROM pending_events ORDER BY id ASC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var rows: [PendingEventRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let e164 = String(cString: sqlite3_column_text(statement, 1))
            let outcome = String(cString: sqlite3_column_text(statement, 2))
            let surface = sqlite3_column_text(statement, 3) != nil ? String(cString: sqlite3_column_text(statement, 3)) : nil
            let displayedAt = String(cString: sqlite3_column_text(statement, 4))
            let eventKey = sqlite3_column_text(statement, 5) != nil ? String(cString: sqlite3_column_text(statement, 5)) : nil
            let metaJson = sqlite3_column_text(statement, 6) != nil ? String(cString: sqlite3_column_text(statement, 6)) : nil
            let createdAt = sqlite3_column_int64(statement, 7)
            rows.append(PendingEventRow(
                id: id,
                phoneNumberE164: e164,
                outcome: outcome,
                surface: surface,
                displayedAt: displayedAt,
                eventKey: eventKey,
                metaJson: metaJson,
                createdAt: createdAt
            ))
        }
        sqlite3_finalize(statement)
        return rows
    }

    func deletePendingEvents(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM pending_events WHERE id IN (\(placeholders));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        for (idx, id) in ids.enumerated() {
            sqlite3_bind_int64(statement, Int32(idx + 1), id)
        }
        _ = sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func prunePendingEvents(olderThanDays days: Int) {
        let cutoff = Int64(Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60)).timeIntervalSince1970)
        let sql = "DELETE FROM pending_events WHERE created_at < ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(statement, 1, cutoff)
        _ = sqlite3_step(statement)
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

    struct PendingTelemetryRow {
        let id: Int64
        let level: String
        let message: String
        let metaJson: String?
        let occurredAt: String
        let createdAt: Int64
    }

    func insertPendingTelemetry(level: String, message: String, metaJson: String?, occurredAt: String) {
        let sql = "INSERT INTO pending_telemetry (level, message, meta_json, occurred_at, created_at) VALUES (?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }

        sqlite3_bind_text(statement, 1, level, -1, nil)
        sqlite3_bind_text(statement, 2, message, -1, nil)
        if let metaJson = metaJson {
            sqlite3_bind_text(statement, 3, metaJson, -1, nil)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, occurredAt, -1, nil)
        sqlite3_bind_int64(statement, 5, Int64(Date().timeIntervalSince1970))

        _ = sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func listPendingTelemetry(limit: Int) -> [PendingTelemetryRow] {
        let sql = "SELECT id, level, message, meta_json, occurred_at, created_at FROM pending_telemetry ORDER BY id ASC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var rows: [PendingTelemetryRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let level = String(cString: sqlite3_column_text(statement, 1))
            let msg = String(cString: sqlite3_column_text(statement, 2))
            let meta = sqlite3_column_text(statement, 3) != nil ? String(cString: sqlite3_column_text(statement, 3)) : nil
            let occurredAt = String(cString: sqlite3_column_text(statement, 4))
            let createdAt = sqlite3_column_int64(statement, 5)
            rows.append(PendingTelemetryRow(id: id, level: level, message: msg, metaJson: meta, occurredAt: occurredAt, createdAt: createdAt))
        }
        sqlite3_finalize(statement)
        return rows
    }

    func deletePendingTelemetry(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM pending_telemetry WHERE id IN (\(placeholders));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        for (idx, id) in ids.enumerated() {
            sqlite3_bind_int64(statement, Int32(idx + 1), id)
        }
        _ = sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func prunePendingTelemetry(olderThanDays days: Int) {
        let cutoff = Int64(Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60)).timeIntervalSince1970)
        let sql = "DELETE FROM pending_telemetry WHERE created_at < ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(statement, 1, cutoff)
        _ = sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
}

