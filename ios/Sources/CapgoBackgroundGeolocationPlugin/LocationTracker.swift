import Foundation
import CoreLocation
import UIKit

/// Singleton that owns the CLLocationManager and persists independently
/// of the Capacitor plugin lifecycle. This ensures background tracking
/// continues even when the WebView suspends.
class LocationTracker: NSObject, CLLocationManagerDelegate {

    static let shared = LocationTracker()

    private var locationManager: CLLocationManager?
    private(set) var locationBuffer: LocationBuffer = LocationBuffer()
    private(set) var httpPoster: HeadlessHttpPoster = HeadlessHttpPoster()

    private var isUpdatingLocation = false
    private var locationsSinceLastPost = 0
    private var postBatchThreshold = 5
    private var maxTrackingDurationMs: Double = 43200000
    private var autoStopTimer: Timer?

    var isTracking: Bool { locationManager != nil && isUpdatingLocation }

    // Callback to forward locations to the JS layer (set by plugin)
    var onLocationUpdate: ((CLLocation) -> Void)?

    // UserDefaults keys
    private static let keyIsTracking = "bg_geo_is_tracking"
    private static let keyTrackingStartTime = "bg_geo_tracking_start_time"
    private static let keyDistanceFilter = "bg_geo_distance_filter"
    private static let keyMaxDuration = "bg_geo_max_duration"

    private override init() {
        super.init()
    }

    // MARK: - Debug Log File

    private func debugLog(_ message: String) {
        NSLog("[BackgroundGeolocation] %@", message)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        let fileURL = try! FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("bg_geo_debug.log")

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.data(using: .utf8)?.write(to: fileURL)
        }
    }

    // MARK: - Start

    func start(distanceFilter: Double, maxDuration: Double, requestPermissions: Bool) {
        guard locationManager == nil else {
            debugLog("Already tracking, ignoring start()")
            return
        }

        self.maxTrackingDurationMs = maxDuration

        let manager = CLLocationManager()
        manager.delegate = self

        let externalPower: Bool = [.full, .charging].contains(UIDevice.current.batteryState)
        manager.desiredAccuracy = externalPower ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        manager.distanceFilter = distanceFilter > 0 ? distanceFilter : kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .otherNavigation

        self.locationManager = manager

        // Save state for recovery
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.keyIsTracking)
        defaults.set(Date().timeIntervalSince1970 * 1000, forKey: Self.keyTrackingStartTime)
        defaults.set(distanceFilter, forKey: Self.keyDistanceFilter)
        defaults.set(maxDuration, forKey: Self.keyMaxDuration)

        debugLog("Starting tracking. distanceFilter=\(distanceFilter), maxDuration=\(maxDuration), authStatus=\(manager.authorizationStatus.rawValue)")

        // Request permissions if needed
        if requestPermissions {
            let status = manager.authorizationStatus
            if status == .notDetermined || status == .denied || status == .restricted {
                manager.requestAlwaysAuthorization()
                // Will start in didChangeAuthorization
                return
            }
            if status == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
        }

        startLocationUpdates()
    }

    // MARK: - Stop

    func stop() {
        debugLog("Stopping tracking. Buffer has \(locationBuffer.getUnsyncedCount()) unsynced locations")

        // Post any remaining buffered locations before stopping
        postRemainingLocations()

        if isUpdatingLocation {
            locationManager?.stopUpdatingLocation()
            locationManager?.stopMonitoringSignificantLocationChanges()
            isUpdatingLocation = false
        }

        locationManager?.delegate = nil
        locationManager = nil

        autoStopTimer?.invalidate()
        autoStopTimer = nil
        locationsSinceLastPost = 0

        // Clear persisted state
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Self.keyIsTracking)
        defaults.removeObject(forKey: Self.keyTrackingStartTime)
    }

    // MARK: - Restore after app relaunch

    func restoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.keyIsTracking) else { return }

        let startTime = defaults.double(forKey: Self.keyTrackingStartTime)
        let maxDuration = defaults.double(forKey: Self.keyMaxDuration)
        let elapsed = Date().timeIntervalSince1970 * 1000 - startTime

        if maxDuration > 0 && elapsed >= maxDuration {
            debugLog("Max duration exceeded, not restoring")
            defaults.set(false, forKey: Self.keyIsTracking)
            return
        }

        let distanceFilter = defaults.double(forKey: Self.keyDistanceFilter)
        debugLog("Restoring tracking. elapsed=\(elapsed)ms, distanceFilter=\(distanceFilter)")

        start(distanceFilter: distanceFilter, maxDuration: maxDuration, requestPermissions: false)

        // Adjust auto-stop for remaining time
        let remaining = maxDuration - elapsed
        startAutoStopTimer(remainingMs: remaining)
    }

    // MARK: - Location Updates

    private func startLocationUpdates() {
        guard let manager = locationManager, !isUpdatingLocation else { return }

        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        isUpdatingLocation = true

        debugLog("Location updates started. allowsBackground=\(manager.allowsBackgroundLocationUpdates), showsIndicator=\(manager.showsBackgroundLocationIndicator)")

        startAutoStopTimer(remainingMs: maxTrackingDurationMs)
    }

    // MARK: - Auto Stop

    private func startAutoStopTimer(remainingMs: Double) {
        autoStopTimer?.invalidate()
        let seconds = max(remainingMs / 1000.0, 1.0)

        autoStopTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.debugLog("Auto-stop: max tracking duration reached")
            self?.stop()
        }
    }

    // MARK: - Posting

    private func postBufferedLocationsInBackground() {
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "LocationPost") {
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.httpPoster.postBatch(self.locationBuffer)

            DispatchQueue.main.async {
                if bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                }
            }
        }
    }

    private func postRemainingLocations() {
        let count = locationBuffer.getUnsyncedCount()
        guard count > 0 else { return }
        debugLog("Posting \(count) remaining locations on stop")

        // Synchronous post on current thread
        httpPoster.postBatch(locationBuffer)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        locationBuffer.insert(location)
        locationsSinceLastPost += 1

        debugLog("Location: \(location.coordinate.latitude), \(location.coordinate.longitude) (acc: \(location.horizontalAccuracy), spd: \(location.speed)) [\(locationsSinceLastPost) since post]")

        if locationsSinceLastPost >= postBatchThreshold {
            locationsSinceLastPost = 0
            postBufferedLocationsInBackground()
        }

        // Forward to plugin for JS callback
        onLocationUpdate?(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clErr = error as? CLError, clErr.code == .locationUnknown {
            return // Transient, ignore
        }
        debugLog("Location error: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        debugLog("Authorization changed: \(status.rawValue)")
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            startLocationUpdates()
        }
    }
}
