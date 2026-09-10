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
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, "CREATE TABLE buffered_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, lat REAL NOT NULL, lng REAL NOT NULL, accuracy REAL, speed REAL, bearing REAL, altitude REAL, timestamp INTEGER NOT NULL, synced INTEGER DEFAULT 0)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO buffered_locations (lat,lng,timestamp) VALUES (19,73,1000)", nil, nil, nil)
        sqlite3_close(db)
        let buffer = LocationBuffer(databasePath: path, defaults: defaults)
        XCTAssertEqual(buffer.getUnsyncedCount(), 1)
        XCTAssertEqual(buffer.getUnsyncedBatch(20).first?["mockLocationStatus"] as? String, "unknown")
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
}
