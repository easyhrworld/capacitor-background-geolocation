import Foundation
import SQLite3
import CoreLocation

/// SQLite-backed buffer for location records.
/// Mirrors the Android LocationBuffer.java implementation.
class LocationBuffer {

    private static let dbName = "bg_geo_locations.db"
    private static let tableName = "buffered_locations"
    private var db: OpaquePointer?
    private let defaults: UserDefaults

    init(databasePath: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openDatabase(databasePath)
        createTableIfNeeded()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase(_ databasePath: String?) {
        let fileURL = try! FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(LocationBuffer.dbName)

        if sqlite3_open(databasePath ?? fileURL.path, &db) != SQLITE_OK {
            print("[BackgroundGeolocation] Failed to open database")
            db = nil
        }
    }

    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS \(LocationBuffer.tableName) (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            accuracy REAL,
            speed REAL,
            bearing REAL,
            altitude REAL,
            timestamp INTEGER NOT NULL,
            synced INTEGER DEFAULT 0
        )
        """
        execute(sql)
        // Upgrade in place. Previously buffered fixes have no OS evidence.
        var stmt: OpaquePointer?
        var columns = Set<String>()
        if sqlite3_prepare_v2(db, "PRAGMA table_info(buffered_locations)", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                columns.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
        }
        sqlite3_finalize(stmt)
        if !columns.contains("mockLocationStatus") {
            execute("ALTER TABLE buffered_locations ADD COLUMN mockLocationStatus TEXT NOT NULL DEFAULT 'unknown'")
        }
        if !columns.contains("ownerTenant") {
            execute("ALTER TABLE buffered_locations ADD COLUMN ownerTenant TEXT NOT NULL DEFAULT ''")
            execute("ALTER TABLE buffered_locations ADD COLUMN ownerEmployee TEXT NOT NULL DEFAULT ''")
            var migration: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE buffered_locations SET ownerTenant = ?, ownerEmployee = ?", -1, &migration, nil) == SQLITE_OK {
                bindOwner(migration)
                sqlite3_step(migration)
            }
            sqlite3_finalize(migration)
        }
    }

    // MARK: - Insert

    func insert(_ location: CLLocation) {
        let sql = """
        INSERT INTO \(LocationBuffer.tableName)
        (lat, lng, accuracy, speed, bearing, altitude, timestamp, mockLocationStatus, ownerTenant, ownerEmployee, synced)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[BackgroundGeolocation] Failed to prepare insert statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, location.coordinate.latitude)
        sqlite3_bind_double(stmt, 2, location.coordinate.longitude)
        sqlite3_bind_double(stmt, 3, location.horizontalAccuracy)
        sqlite3_bind_double(stmt, 4, location.speed >= 0 ? location.speed : 0)
        sqlite3_bind_double(stmt, 5, location.course >= 0 ? location.course : 0)
        sqlite3_bind_double(stmt, 6, location.altitude)
        sqlite3_bind_int64(stmt, 7, Int64(location.timestamp.timeIntervalSince1970 * 1000))

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 8, locationEvidenceStatus(location), -1, transient)
        bindOwner(stmt, startingAt: 9)

        if sqlite3_step(stmt) != SQLITE_DONE {
            print("[BackgroundGeolocation] Failed to insert location")
        }
    }

    // MARK: - Query

    func getUnsyncedBatch(_ batchSize: Int, ownerTenant: String? = nil, ownerEmployee: String? = nil) -> [[String: Any]] {
        let sql = """
        SELECT id, lat, lng, accuracy, speed, bearing, altitude, timestamp, mockLocationStatus
        FROM \(LocationBuffer.tableName)
        WHERE synced = 0 AND ownerTenant = ? AND ownerEmployee = ?
        ORDER BY id ASC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bindOwner(stmt, tenant: ownerTenant, employee: ownerEmployee)
        sqlite3_bind_int(stmt, 3, Int32(batchSize))

        bindOwner(stmt, tenant: ownerTenant, employee: ownerEmployee)
        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row: [String: Any] = [
                "id": sqlite3_column_int64(stmt, 0),
                "lat": sqlite3_column_double(stmt, 1),
                "lng": sqlite3_column_double(stmt, 2),
                "accuracy": sqlite3_column_double(stmt, 3),
                "speed": sqlite3_column_double(stmt, 4),
                "bearing": sqlite3_column_double(stmt, 5),
                "altitude": sqlite3_column_double(stmt, 6),
                "timestamp": sqlite3_column_int64(stmt, 7),
                "mockLocationStatus": String(cString: sqlite3_column_text(stmt, 8)),
            ]
            results.append(row)
        }
        return results
    }

    func getAll() -> [[String: Any]] {
        let sql = """
        SELECT lat, lng, accuracy, speed, bearing, altitude, timestamp, mockLocationStatus
        FROM \(LocationBuffer.tableName)
        WHERE ownerTenant = ? AND ownerEmployee = ?
        ORDER BY id ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bindOwner(stmt)
        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row: [String: Any] = [
                "lat": sqlite3_column_double(stmt, 0),
                "lng": sqlite3_column_double(stmt, 1),
                "accuracy": sqlite3_column_double(stmt, 2),
                "speed": sqlite3_column_double(stmt, 3),
                "bearing": sqlite3_column_double(stmt, 4),
                "altitude": sqlite3_column_double(stmt, 5),
                "timestamp": sqlite3_column_int64(stmt, 6),
                "mockLocationStatus": String(cString: sqlite3_column_text(stmt, 7)),
            ]
            results.append(row)
        }
        return results
    }

    // MARK: - Sync

    func markSynced(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "UPDATE \(LocationBuffer.tableName) SET synced = 1 WHERE id IN (\(placeholders))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), id)
        }
        sqlite3_step(stmt)
    }

    func deleteSynced() {
        execute("DELETE FROM \(LocationBuffer.tableName) WHERE synced = 1")
    }

    // MARK: - Clear

    func clearAll() {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM buffered_locations WHERE ownerTenant = ? AND ownerEmployee = ?", -1, &stmt, nil) == SQLITE_OK {
            bindOwner(stmt)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func getUnsyncedCount() -> Int {
        let sql = "SELECT COUNT(*) FROM \(LocationBuffer.tableName) WHERE synced = 0 AND ownerTenant = ? AND ownerEmployee = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        bindOwner(stmt)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    // MARK: - Helpers

    private func bindOwner(_ stmt: OpaquePointer?, startingAt index: Int32 = 1, tenant: String? = nil, employee: String? = nil) {
        objc_sync_enter(defaults)
        defer { objc_sync_exit(defaults) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, tenant ?? defaults.string(forKey: "bg_geo_tenant_id") ?? "", -1, transient)
        sqlite3_bind_text(stmt, index + 1, employee ?? defaults.string(forKey: "bg_geo_employee_id") ?? "", -1, transient)
    }

    private func execute(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            print("[BackgroundGeolocation] SQL error: \(errmsg)")
        }
    }
}
