import Foundation
import SQLite3
import CoreLocation

/// SQLite-backed buffer for location records.
/// Mirrors the Android LocationBuffer.java implementation.
class LocationBuffer {

    private static let dbName = "bg_geo_locations.db"
    private static let tableName = "buffered_locations"
    private var db: OpaquePointer?

    init() {
        openDatabase()
        createTableIfNeeded()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let fileURL = try! FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(LocationBuffer.dbName)

        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
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
    }

    // MARK: - Insert

    func insert(_ location: CLLocation) {
        let sql = """
        INSERT INTO \(LocationBuffer.tableName)
        (lat, lng, accuracy, speed, bearing, altitude, timestamp, synced)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0)
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

        if sqlite3_step(stmt) != SQLITE_DONE {
            print("[BackgroundGeolocation] Failed to insert location")
        }
    }

    // MARK: - Query

    func getUnsyncedBatch(_ batchSize: Int) -> [[String: Any]] {
        let sql = """
        SELECT id, lat, lng, accuracy, speed, bearing, altitude, timestamp
        FROM \(LocationBuffer.tableName)
        WHERE synced = 0
        ORDER BY id ASC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(batchSize))

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
            ]
            results.append(row)
        }
        return results
    }

    func getAll() -> [[String: Any]] {
        let sql = """
        SELECT lat, lng, accuracy, speed, bearing, altitude, timestamp
        FROM \(LocationBuffer.tableName)
        ORDER BY id ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

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
        execute("DELETE FROM \(LocationBuffer.tableName)")
    }

    func getUnsyncedCount() -> Int {
        let sql = "SELECT COUNT(*) FROM \(LocationBuffer.tableName) WHERE synced = 0"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    // MARK: - Helpers

    private func execute(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            print("[BackgroundGeolocation] SQL error: \(errmsg)")
        }
    }
}
