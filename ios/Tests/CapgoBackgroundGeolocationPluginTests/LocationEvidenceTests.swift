import XCTest
import CoreLocation
import SQLite3
@testable import CapgoBackgroundGeolocationPlugin

private final class UnattributedLocation: CLLocation {
    override var sourceInformation: CLLocationSourceInformation? { nil }
}

final class LocationEvidenceTests: XCTestCase {
    private var path: String!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        defaults.set("tenant", forKey: "bg_geo_tenant_id")
        defaults.set("alice", forKey: "bg_geo_employee_id")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        defaults.removePersistentDomain(forName: suite)
    }

    private func location(mocked: Bool) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 19, longitude: 73),
                   altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                   course: 0, courseAccuracy: 1, speed: 0, speedAccuracy: 1, timestamp: Date(),
                   sourceInfo: CLLocationSourceInformation(softwareSimulationState: mocked, andExternalAccessoryState: false))
    }

    func testDistinguishesMockedNegativeAndUnavailableEvidence() {
        XCTAssertEqual(locationEvidenceStatus(location(mocked: true)), "mocked")
        XCTAssertEqual(locationEvidenceStatus(location(mocked: false)), "not_detected")
        XCTAssertEqual(locationEvidenceStatus(UnattributedLocation(latitude: 19, longitude: 73)), "unknown")
    }

    func testPersistsEvidenceAcrossReopenAndUploadBatch() {
        var buffer: LocationBuffer? = LocationBuffer(databasePath: path, defaults: defaults)
        buffer?.insert(location(mocked: true))
        buffer = nil
        buffer = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer?.getAll().first?["mockLocationStatus"] as? String, "mocked")
        XCTAssertEqual(buffer?.getUnsyncedBatch(20).first?["mockLocationStatus"] as? String, "mocked")
    }

    func testLegacyBufferMigrationKeepsQueuedPointsUnknown() {
        createLegacyBuffer()
        let buffer = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer.getUnsyncedCount(), 1)
        XCTAssertEqual(buffer.getUnsyncedBatch(20).first?["mockLocationStatus"] as? String, "unknown")
    }

    func testRepairsUpgradeInterruptedAfterEvidenceColumn() {
        assertInterruptedUpgradeRecovery(addedColumns: 1)
    }

    func testRepairsUpgradeInterruptedAfterTenantColumn() {
        assertInterruptedUpgradeRecovery(addedColumns: 2)
    }

    func testRepairsUpgradeInterruptedBeforeOwnerBackfill() {
        assertInterruptedUpgradeRecovery(addedColumns: 3)
    }

    func testRecoveryPreservesExistingOwnersAndEvidence() {
        createLegacyBuffer(addedColumns: 3)
        withDatabase { db in
            execute("INSERT INTO buffered_locations (lat,lng,timestamp,mockLocationStatus,ownerTenant,ownerEmployee) VALUES (20,74,2000,'mocked','other-tenant','bob')", on: db)
        }
        var buffer: LocationBuffer? = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer?.getUnsyncedCount(), 1)
        buffer = nil

        defaults.set("other-tenant", forKey: "bg_geo_tenant_id")
        defaults.set("bob", forKey: "bg_geo_employee_id")
        buffer = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer?.getUnsyncedCount(), 1)
        XCTAssertEqual(buffer?.getUnsyncedBatch(20).first?["mockLocationStatus"] as? String, "mocked")
        XCTAssertEqual(buffer?.getUnsyncedBatch(20).first?["timestamp"] as? Int64, 2000)
    }

    func testCompletedMigrationDoesNotReassignUnownedRecordsOnReopen() {
        createLegacyBuffer()
        var buffer: LocationBuffer? = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer?.getUnsyncedCount(), 1)
        buffer = nil
        withDatabase { db in
            execute("INSERT INTO buffered_locations (lat,lng,timestamp) VALUES (20,74,2000)", on: db)
        }

        defaults.set("bob", forKey: "bg_geo_employee_id")
        buffer = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer?.getUnsyncedCount(), 0)
        defaults.set("alice", forKey: "bg_geo_employee_id")
        XCTAssertEqual(buffer?.getUnsyncedCount(), 1)
    }

    func testFailedBackfillRollsBackSchemaAndCanRetryOnReopen() {
        createLegacyBuffer()
        withDatabase { db in
            execute("CREATE TRIGGER fail_backfill BEFORE UPDATE ON buffered_locations BEGIN SELECT RAISE(ABORT, 'injected migration failure'); END", on: db)
        }
        // The trigger fails after all ALTERs, exercising rollback of the entire upgrade.
        autoreleasepool {
            _ = LocationBuffer(databasePath: path, defaults: defaults)
        }
        withDatabase { db in
            XCTAssertEqual(integer("SELECT COUNT(*) FROM pragma_table_info('buffered_locations') WHERE name IN ('mockLocationStatus','ownerTenant','ownerEmployee')", on: db), 0)
            XCTAssertEqual(integer("PRAGMA user_version", on: db), 0)
            XCTAssertEqual(integer("SELECT COUNT(*) FROM buffered_locations", on: db), 1)
            execute("DROP TRIGGER fail_backfill", on: db)
        }

        let buffer = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer.getUnsyncedCount(), 1)
        XCTAssertEqual(buffer.getUnsyncedBatch(20).first?["mockLocationStatus"] as? String, "unknown")
        buffer.insert(location(mocked: true))
        XCTAssertEqual(buffer.getUnsyncedCount(), 2)
    }

    func testEmployeeSwitchCannotUploadOrClearAnotherEmployeesEvidence() {
        let buffer = LocationBuffer(databasePath: path, defaults: defaults)
        buffer.insert(location(mocked: true))
        defaults.set("bob", forKey: "bg_geo_employee_id")
        XCTAssertTrue(buffer.getUnsyncedBatch(20).isEmpty)
        buffer.clearAll()
        defaults.set("alice", forKey: "bg_geo_employee_id")
        XCTAssertEqual(buffer.getUnsyncedCount(), 1)
    }

    private func assertInterruptedUpgradeRecovery(addedColumns: Int) {
        createLegacyBuffer(addedColumns: addedColumns)
        var buffer: LocationBuffer? = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer?.getUnsyncedCount(), 1)
        let legacy = buffer?.getUnsyncedBatch(20).first
        XCTAssertEqual(legacy?["mockLocationStatus"] as? String, "unknown")
        XCTAssertEqual(legacy?["timestamp"] as? Int64, 1000)
        XCTAssertEqual(legacy?["lat"] as? Double, 19)
        buffer?.insert(location(mocked: true))
        XCTAssertEqual(buffer?.getUnsyncedCount(), 2)
        buffer = nil
        withDatabase { db in
            XCTAssertEqual(integer("PRAGMA user_version", on: db), 2)
        }
        buffer = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer?.getUnsyncedCount(), 2)
        XCTAssertEqual(buffer?.getUnsyncedBatch(20).last?["mockLocationStatus"] as? String, "mocked")
    }

    private func createLegacyBuffer(addedColumns: Int = 0) {
        withDatabase { db in
            execute("CREATE TABLE buffered_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, lat REAL NOT NULL, lng REAL NOT NULL, accuracy REAL, speed REAL, bearing REAL, altitude REAL, timestamp INTEGER NOT NULL, synced INTEGER DEFAULT 0)", on: db)
            execute("INSERT INTO buffered_locations (lat,lng,timestamp) VALUES (19,73,1000)", on: db)
            let columns = [
                "mockLocationStatus TEXT NOT NULL DEFAULT 'unknown'",
                "ownerTenant TEXT NOT NULL DEFAULT ''",
                "ownerEmployee TEXT NOT NULL DEFAULT ''",
            ]
            for column in columns.prefix(addedColumns) {
                execute("ALTER TABLE buffered_locations ADD COLUMN \(column)", on: db)
            }
        }
    }

    private func withDatabase(_ body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        guard let db = db else { return }
        defer { sqlite3_close(db) }
        body(db)
    }

    private func execute(_ sql: String, on db: OpaquePointer) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func integer(_ sql: String, on db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int(stmt, 0))
    }
}
