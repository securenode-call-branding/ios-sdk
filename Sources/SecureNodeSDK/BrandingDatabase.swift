import Foundation
import SQLite3

/// Active Caller Identity field max lengths (database/API constraints per spec).
private enum BrandingFieldMaxLength {
    static let phoneNumberE164 = 20
    static let brandName = 100
    static let logoUrl = 2048
    static let callReason = 200
}

/**
 * Local SQLite database for branding cache.
 * Use BrandingDatabase.shared for a single process-wide instance; all access is serialized on an internal queue.
 * All stored fields are clamped to spec max lengths (phone_number_e164 20, brand_name 100, logo_url 2048, call_reason 200).
 */
class BrandingDatabase {
    static let shared = BrandingDatabase()

    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.securenode.brandingdb", qos: .utility)

    private static func clamp(_ value: String?, maxLength: Int) -> String? {
        guard let value = value, !value.isEmpty else { return value }
        if value.count <= maxLength { return value }
        return String(value.prefix(maxLength))
    }

    private static func clampRequired(_ value: String, maxLength: Int) -> String {
        if value.count <= maxLength { return value }
        return String(value.prefix(maxLength))
    }

    // Ensure SQLite copies Swift strings safely
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @inline(__always)
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text = text {
            text.withCString { cStr in
                sqlite3_bind_text(stmt, index, cStr, -1, Self.SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    @inline(__always)
    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    @inline(__always)
    private func lastErrorMessage() -> String {
        if let cStr = sqlite3_errmsg(db) {
            return String(cString: cStr)
        }
        return "Unknown SQLite error"
    }

    @inline(__always)
    private func isInTransaction() -> Bool {
        // sqlite3_get_autocommit returns 0 if a transaction is active
        return sqlite3_get_autocommit(db) == 0
    }

    private func beginTransaction() {
        _ = sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
    }

    private func commitTransaction() {
        _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    private func rollbackTransaction() {
        _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
    }

    @discardableResult
    private func quickCheck() -> Bool {
        var stmt: OpaquePointer?
        let sql = "PRAGMA quick_check;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("quick_check prepare failed: \(lastErrorMessage())")
            return false
        }
        var ok = false
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let res = sqlite3_column_text(stmt, 0) {
                let msg = String(cString: res)
                ok = (msg == "ok")
                if !ok {
                    print("PRAGMA quick_check reported: \(msg)")
                }
            }
        }
        sqlite3_finalize(stmt)
        return ok
    }
    
    init() {
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dbPath = documentsPath.appendingPathComponent("securenode_branding.db").path

        openDatabase()
        createTable()
        #if DEBUG
        print("BrandingDatabase init: opened at \(dbPath)")
        #endif
    }

    deinit {
        #if DEBUG
        print("BrandingDatabase deinit: closing")
        #endif
        closeDatabase()
    }
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Error opening database: \(lastErrorMessage())")
            return
        }
        // Avoid busy errors under concurrent access
        sqlite3_busy_timeout(db, 5000)
        // Configure durability/performance pragmas
        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }
    
    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        let colNameIdx = 1
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, Int32(colNameIdx)) {
                let name = String(cString: cStr)
                if name == column { return true }
            }
        }
        return false
    }

    private func addColumnIfNeeded(table: String, column: String, def: String) {
        guard !columnExists(table: table, column: column) else { return }
        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(def);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
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
                print("BrandingDatabase createTable branding step failed: \(lastErrorMessage())")
            }
        } else {
            print("BrandingDatabase createTable branding prepare failed: \(lastErrorMessage())")
        }
        sqlite3_finalize(statement)

        addColumnIfNeeded(table: "branding", column: "brand_id", def: "TEXT")

        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, createPendingEventsSQL, -1, &stmt2, nil) == SQLITE_OK {
            if sqlite3_step(stmt2) != SQLITE_DONE {
                print("BrandingDatabase createTable pending_events step failed: \(lastErrorMessage())")
            }
        } else {
            print("BrandingDatabase createTable pending_events prepare failed: \(lastErrorMessage())")
        }
        sqlite3_finalize(stmt2)

        addColumnIfNeeded(table: "pending_events", column: "event_key", def: "TEXT")
        addColumnIfNeeded(table: "pending_events", column: "meta_json", def: "TEXT")

        var stmt3: OpaquePointer?
        if sqlite3_prepare_v2(db, createPendingTelemetrySQL, -1, &stmt3, nil) == SQLITE_OK {
            if sqlite3_step(stmt3) != SQLITE_DONE {
                print("BrandingDatabase createTable pending_telemetry step failed: \(lastErrorMessage())")
            }
        } else {
            print("BrandingDatabase createTable pending_telemetry prepare failed: \(lastErrorMessage())")
        }
        sqlite3_finalize(stmt3)

        addColumnIfNeeded(table: "pending_telemetry", column: "meta_json", def: "TEXT")
        addColumnIfNeeded(table: "pending_telemetry", column: "occurred_at", def: "TEXT")

        // Helpful index for pruning/ordering
        var idxStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "CREATE INDEX IF NOT EXISTS idx_pending_events_created_at ON pending_events(created_at);", -1, &idxStmt, nil) == SQLITE_OK {
            _ = sqlite3_step(idxStmt)
        }
        sqlite3_finalize(idxStmt)

        // Uniqueness for event_key to avoid duplicate events when set
        var uniqueEventKeyStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_events_event_key ON pending_events(event_key) WHERE event_key IS NOT NULL;", -1, &uniqueEventKeyStmt, nil) == SQLITE_OK {
            _ = sqlite3_step(uniqueEventKeyStmt)
        }
        sqlite3_finalize(uniqueEventKeyStmt)

        var idxStmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "CREATE INDEX IF NOT EXISTS idx_pending_telemetry_created_at ON pending_telemetry(created_at);", -1, &idxStmt2, nil) == SQLITE_OK {
            _ = sqlite3_step(idxStmt2)
        }
        sqlite3_finalize(idxStmt2)

        // Run a quick integrity check (best-effort)
        _ = quickCheck()
    }
    
    /**
     * List all branding entries (e.g. for demo UI). Ordered by updated_at DESC.
     */
    func listAllBranding(limit: Int = 500) -> [BrandingInfo] {
        queue.sync {
            listAllBrandingImpl(limit: limit)
        }
    }

    /**
     * Get branding for a phone number
     */
    func getBranding(for phoneNumber: String) -> BrandingInfo? {
        queue.sync {
            getBrandingImpl(for: phoneNumber)
        }
    }

    private func listAllBrandingImpl(limit: Int) -> [BrandingInfo] {
        let sql = "SELECT phone_number_e164, brand_name, logo_url, call_reason, brand_id, updated_at FROM branding ORDER BY updated_at DESC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var result: [BrandingInfo] = []
        let dateFormatter = ISO8601DateFormatter()
        while sqlite3_step(statement) == SQLITE_ROW {
            let e164 = columnText(statement, 0) ?? ""
            let brandName = columnText(statement, 1)
            let logoUrl = columnText(statement, 2)
            let callReason = columnText(statement, 3)
            let brandId = columnText(statement, 4)
            let updatedAtInt = sqlite3_column_int64(statement, 5)
            let date = Date(timeIntervalSince1970: TimeInterval(updatedAtInt))
            let updatedAtString = dateFormatter.string(from: date)
            result.append(BrandingInfo(
                phoneNumberE164: e164,
                brandName: brandName,
                logoUrl: logoUrl,
                callReason: callReason,
                brandId: brandId,
                updatedAt: updatedAtString
            ))
        }
        sqlite3_finalize(statement)
        return result
    }

    private func getBrandingImpl(for phoneNumber: String) -> BrandingInfo? {
        let querySQL = "SELECT phone_number_e164, brand_name, logo_url, call_reason, brand_id, updated_at FROM branding WHERE phone_number_e164 = ? LIMIT 1;"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        
        bindText(statement, 1, phoneNumber)
        
        var branding: BrandingInfo? = nil
        
        if sqlite3_step(statement) == SQLITE_ROW {
            guard
                let e164 = columnText(statement, 0),
                let brandName = columnText(statement, 1)
            else {
                sqlite3_finalize(statement)
                return nil
            }
            let logoUrl = columnText(statement, 2)
            let callReason = columnText(statement, 3)
            let brandId = columnText(statement, 4)
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
        queue.sync {
            saveBrandingImpl(brandingList)
        }
    }

    private func saveBrandingImpl(_ brandingList: [BrandingInfo]) {
        let insertSQL = "INSERT OR REPLACE INTO branding (phone_number_e164, brand_name, logo_url, call_reason, brand_id, updated_at) VALUES (?, ?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            print("saveBranding prepare failed: \(lastErrorMessage())")
            return
        }

        let startedTx: Bool
        if !isInTransaction() {
            beginTransaction()
            startedTx = true
        } else {
            startedTx = false
        }

        var success = true
        for branding in brandingList {
            bindText(statement, 1, Self.clampRequired(branding.phoneNumberE164, maxLength: BrandingFieldMaxLength.phoneNumberE164))
            bindText(statement, 2, Self.clampRequired(branding.brandName ?? "", maxLength: BrandingFieldMaxLength.brandName))
            bindText(statement, 3, Self.clamp(branding.logoUrl, maxLength: BrandingFieldMaxLength.logoUrl))
            bindText(statement, 4, Self.clamp(branding.callReason, maxLength: BrandingFieldMaxLength.callReason))
            bindText(statement, 5, branding.brandId)
            sqlite3_bind_int64(statement, 6, Int64(Date().timeIntervalSince1970))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error inserting branding: \(lastErrorMessage())")
                success = false
                break
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }

        sqlite3_finalize(statement)

        if startedTx {
            if success {
                commitTransaction()
            } else {
                rollbackTransaction()
            }
        }
    }

    /**
     * Replace local branding cache with the server-authoritative list.
     * This is used when syncing with `since == nil` so removals (paused/deleted) are reflected immediately.
     */
    func replaceAllBranding(_ brandingList: [BrandingInfo]) {
        queue.sync {
            replaceAllBrandingImpl(brandingList)
        }
    }

    private func replaceAllBrandingImpl(_ brandingList: [BrandingInfo]) {
        // Perform as a single atomic transaction
        let startedTx: Bool
        if !isInTransaction() {
            beginTransaction()
            startedTx = true
        } else {
            startedTx = false
        }

        var success = true

        // Clear existing
        var deleteStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM branding;", -1, &deleteStmt, nil) == SQLITE_OK {
            if sqlite3_step(deleteStmt) != SQLITE_DONE {
                print("Error clearing branding: \(lastErrorMessage())")
                success = false
            }
        } else {
            print("Error preparing delete branding: \(lastErrorMessage())")
            success = false
        }
        sqlite3_finalize(deleteStmt)

        if success {
            // Insert new (saveBrandingImpl reuses active transaction)
            saveBrandingImpl(brandingList)
        }

        if startedTx {
            if success {
                commitTransaction()
            } else {
                rollbackTransaction()
            }
        }
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
        queue.sync {
            insertPendingEventImpl(phoneNumberE164: phoneNumberE164, outcome: outcome, surface: surface, displayedAt: displayedAt, eventKey: eventKey, metaJson: metaJson)
        }
    }

    private func insertPendingEventImpl(
        phoneNumberE164: String,
        outcome: String,
        surface: String?,
        displayedAt: String,
        eventKey: String?,
        metaJson: String?
    ) {
        let sql = "INSERT OR IGNORE INTO pending_events (phone_number_e164, outcome, surface, displayed_at, event_key, meta_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("BrandingDatabase insertPendingEvent prepare failed: \(lastErrorMessage())")
            return
        }

        bindText(statement, 1, phoneNumberE164)
        bindText(statement, 2, outcome)
        bindText(statement, 3, surface)
        bindText(statement, 4, displayedAt)
        bindText(statement, 5, eventKey)
        bindText(statement, 6, metaJson)
        sqlite3_bind_int64(statement, 7, Int64(Date().timeIntervalSince1970))

        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE {
            print("BrandingDatabase insertPendingEvent step failed: \(stepResult) \(lastErrorMessage())")
        }
        sqlite3_finalize(statement)
    }

    func listPendingEvents(limit: Int) -> [PendingEventRow] {
        queue.sync {
            listPendingEventsImpl(limit: limit)
        }
    }

    private func listPendingEventsImpl(limit: Int) -> [PendingEventRow] {
        let sql = "SELECT id, phone_number_e164, outcome, surface, displayed_at, event_key, meta_json, created_at FROM pending_events ORDER BY id ASC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var rows: [PendingEventRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard
                let e164 = columnText(statement, 1),
                let outcome = columnText(statement, 2),
                let displayedAt = columnText(statement, 4)
            else {
                continue
            }
            let surface = columnText(statement, 3)
            let eventKey = columnText(statement, 5)
            let metaJson = columnText(statement, 6)
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
        queue.sync {
            deletePendingEventsImpl(ids: ids)
        }
    }

    private func deletePendingEventsImpl(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM pending_events WHERE id IN (\(placeholders));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("BrandingDatabase deletePendingEvents prepare failed: \(lastErrorMessage())")
            return
        }
        for (idx, id) in ids.enumerated() {
            sqlite3_bind_int64(statement, Int32(idx + 1), id)
        }
        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE {
            print("BrandingDatabase deletePendingEvents step failed: \(stepResult) \(lastErrorMessage())")
        }
        sqlite3_finalize(statement)
    }

    func prunePendingEvents(olderThanDays days: Int) {
        queue.sync {
            prunePendingEventsImpl(olderThanDays: days)
        }
    }

    private func prunePendingEventsImpl(olderThanDays days: Int) {
        let cutoff = Int64(Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60)).timeIntervalSince1970)
        let sql = "DELETE FROM pending_events WHERE created_at < ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("BrandingDatabase prunePendingEvents prepare failed: \(lastErrorMessage())")
            return
        }
        sqlite3_bind_int64(statement, 1, cutoff)
        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE {
            print("BrandingDatabase prunePendingEvents step failed: \(stepResult) \(lastErrorMessage())")
        }
        sqlite3_finalize(statement)
    }
    
    /**
     * Delete old branding records
     */
    func deleteOldBranding(before date: Date) {
        queue.sync {
            deleteOldBrandingImpl(before: date)
        }
    }

    private func deleteOldBrandingImpl(before date: Date) {
        let cutoffTimestamp = Int64(date.timeIntervalSince1970)
        let deleteSQL = "DELETE FROM branding WHERE updated_at < ?;"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK else {
            print("BrandingDatabase deleteOldBranding prepare failed: \(lastErrorMessage())")
            return
        }

        sqlite3_bind_int64(statement, 1, cutoffTimestamp)

        if sqlite3_step(statement) != SQLITE_DONE {
            print("BrandingDatabase deleteOldBranding step failed: \(lastErrorMessage())")
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
        queue.sync {
            insertPendingTelemetryImpl(level: level, message: message, metaJson: metaJson, occurredAt: occurredAt)
        }
    }

    private func insertPendingTelemetryImpl(level: String, message: String, metaJson: String?, occurredAt: String) {
        let sql = "INSERT INTO pending_telemetry (level, message, meta_json, occurred_at, created_at) VALUES (?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("BrandingDatabase insertPendingTelemetry prepare failed: \(lastErrorMessage())")
            return
        }

        bindText(statement, 1, level)
        bindText(statement, 2, message)
        bindText(statement, 3, metaJson)
        bindText(statement, 4, occurredAt)
        sqlite3_bind_int64(statement, 5, Int64(Date().timeIntervalSince1970))

        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE {
            print("BrandingDatabase insertPendingTelemetry step failed: \(stepResult) \(lastErrorMessage())")
        }
        sqlite3_finalize(statement)
    }

    func listPendingTelemetry(limit: Int) -> [PendingTelemetryRow] {
        queue.sync {
            listPendingTelemetryImpl(limit: limit)
        }
    }

    private func listPendingTelemetryImpl(limit: Int) -> [PendingTelemetryRow] {
        let sql = "SELECT id, level, message, meta_json, occurred_at, created_at FROM pending_telemetry ORDER BY id ASC LIMIT ?;"
        var statement: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            // Optionally, log the error for debugging
            if let errorMessage = sqlite3_errmsg(db) {
                let message = String(cString: errorMessage)
                print("sqlite3_prepare_v2 failed: \(message)")
            }
            return []
        }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var rows: [PendingTelemetryRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard
                let level = columnText(statement, 1),
                let msg = columnText(statement, 2),
                let occurredAt = columnText(statement, 4)
            else {
                continue
            }
            let meta = columnText(statement, 3)
            let createdAt = sqlite3_column_int64(statement, 5)
            rows.append(PendingTelemetryRow(id: id, level: level, message: msg, metaJson: meta, occurredAt: occurredAt, createdAt: createdAt))
        }
        sqlite3_finalize(statement)
        return rows
    }

    func deletePendingTelemetry(ids: [Int64]) {
        queue.sync {
            deletePendingTelemetryImpl(ids: ids)
        }
    }

    private func deletePendingTelemetryImpl(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM pending_telemetry WHERE id IN (\(placeholders));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("BrandingDatabase deletePendingTelemetry prepare failed: \(lastErrorMessage())")
            return
        }
        for (idx, id) in ids.enumerated() {
            sqlite3_bind_int64(statement, Int32(idx + 1), id)
        }
        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE {
            print("BrandingDatabase deletePendingTelemetry step failed: \(stepResult) \(lastErrorMessage())")
        }
        sqlite3_finalize(statement)
    }

    func prunePendingTelemetry(olderThanDays days: Int) {
        queue.sync {
            prunePendingTelemetryImpl(olderThanDays: days)
        }
    }

    private func prunePendingTelemetryImpl(olderThanDays days: Int) {
        let cutoff = Int64(Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60)).timeIntervalSince1970)
        let sql = "DELETE FROM pending_telemetry WHERE created_at < ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("BrandingDatabase prunePendingTelemetry prepare failed: \(lastErrorMessage())")
            return
        }
        sqlite3_bind_int64(statement, 1, cutoff)
        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE {
            print("BrandingDatabase prunePendingTelemetry step failed: \(stepResult) \(lastErrorMessage())")
        }
        sqlite3_finalize(statement)
    }

    @discardableResult
    func runDatabaseChecks() -> Bool {
        queue.sync {
            quickCheck()
        }
    }
}

