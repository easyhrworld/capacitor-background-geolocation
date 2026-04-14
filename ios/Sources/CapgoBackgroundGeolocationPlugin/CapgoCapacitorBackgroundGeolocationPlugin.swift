// swiftlint:disable file_length
import Capacitor
import Foundation
import UIKit
import CoreLocation
import AVFoundation

// Avoids a bewildering type warning.
let null = Optional<Double>.none as Any

func formatLocation(_ location: CLLocation) -> PluginCallResultData {
    var simulated = false
    if #available(iOS 15, *) {
        if let sourceInfo = location.sourceInformation {
            simulated = sourceInfo.isSimulatedBySoftware
        }
    }
    return [
        "latitude": location.coordinate.latitude,
        "longitude": location.coordinate.longitude,
        "accuracy": location.horizontalAccuracy,
        "altitude": location.altitude,
        "altitudeAccuracy": location.verticalAccuracy,
        "simulated": simulated,
        "speed": location.speed < 0 ? null : location.speed,
        "bearing": location.course < 0 ? null : location.course,
        "time": NSNumber(
            value: Int(
                location.timestamp.timeIntervalSince1970 * 1000
            )
        )
    ]
}

@objc(BackgroundGeolocation)
// swiftlint:disable:next type_body_length
public class BackgroundGeolocation: CAPPlugin, CLLocationManagerDelegate, CAPBridgedPlugin {
    private let pluginVersion: String = "8.0.28"
    public let identifier = "BackgroundGeolocationPlugin"
    public let jsName = "BackgroundGeolocation"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnCallback),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openSettings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPlannedRoute", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPluginVersion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "configure", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBufferedLocations", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearBufferedLocations", returnType: CAPPluginReturnPromise),
    ]
    private var locationManager: CLLocationManager?
    private var created: Date?
    private var allowStale: Bool = false
    private var isUpdatingLocation: Bool = false
    private var activeCallbackId: String?
    private var audioPlayer: AVAudioPlayer?
    private var plannedRoute: [[Double]] = []
    private var isOffRoute: Bool = true
    private var distanceThreshold: Double = 50.0

    // Headless mode support
    private var locationBuffer: LocationBuffer?
    private var httpPoster: HeadlessHttpPoster?
    private var postTimer: Timer?
    private var autoStopTimer: Timer?
    private var maxTrackingDurationMs: Double = 43200000 // 12 hours
    private var isBackgroundMode: Bool = false
    private var locationsSinceLastPost: Int = 0
    private var postBatchThreshold: Int = 5 // Post after this many locations

    // UserDefaults keys
    private static let prefsPrefix = "bg_geo_"
    private static let keyIsTracking = "bg_geo_is_tracking"
    private static let keyTrackingStartTime = "bg_geo_tracking_start_time"
    private static let keyDistanceFilter = "bg_geo_distance_filter"
    private static let keyMaxDuration = "bg_geo_max_duration"

    // Earth radius in meters for distance calculations
    private static let earthRadiusMeters: Double = 6371000.0

    @objc override public func load() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        locationBuffer = LocationBuffer()
        httpPoster = HeadlessHttpPoster()

        // Check if we should resume tracking (e.g., after app relaunch by significant location change)
        restoreTrackingIfNeeded()
    }

    // MARK: - Tracking State Persistence

    private func saveTrackingState() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.keyIsTracking)
        defaults.set(Date().timeIntervalSince1970 * 1000, forKey: Self.keyTrackingStartTime)
        defaults.set(maxTrackingDurationMs, forKey: Self.keyMaxDuration)
    }

    private func clearTrackingState() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Self.keyIsTracking)
        defaults.removeObject(forKey: Self.keyTrackingStartTime)
    }

    private func restoreTrackingIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.keyIsTracking) else { return }

        let startTime = defaults.double(forKey: Self.keyTrackingStartTime)
        let maxDuration = defaults.double(forKey: Self.keyMaxDuration)
        let elapsed = Date().timeIntervalSince1970 * 1000 - startTime

        // If exceeded max duration, clear state and don't resume
        if maxDuration > 0 && elapsed >= maxDuration {
            print("[BackgroundGeolocation] Tracking exceeded max duration, not resuming")
            clearTrackingState()
            return
        }

        print("[BackgroundGeolocation] Restoring tracking after app relaunch")

        // Resume tracking in background mode
        DispatchQueue.main.async {
            self.locationManager = CLLocationManager()
            guard let manager = self.locationManager else { return }
            manager.delegate = self
            self.created = Date()

            manager.desiredAccuracy = kCLLocationAccuracyBest
            let distanceFilter = defaults.double(forKey: Self.keyDistanceFilter)
            manager.distanceFilter = distanceFilter > 0 ? distanceFilter : kCLDistanceFilterNone
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.activityType = .otherNavigation

            self.isBackgroundMode = true
            self.maxTrackingDurationMs = maxDuration > 0 ? maxDuration : 43200000

            manager.startUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
            self.isUpdatingLocation = true

            self.startAutoStopTimer(remainingMs: maxDuration - elapsed)
            self.startPostTimer()
        }
    }

    // MARK: - Start / Stop

    @objc func start(_ call: CAPPluginCall) {
        call.keepAlive = true

        DispatchQueue.main.async {
            if self.locationManager != nil {
                return call.reject("Location tracking already started", "ALREADY_STARTED")
            }

            self.locationManager = CLLocationManager()
            guard let manager = self.locationManager else {
                return call.reject("Failed to create location manager")
            }
            manager.delegate = self
            self.created = Date()

            let background = call.getString("backgroundMessage") != nil
            self.allowStale = call.getBool("stale") ?? false
            self.activeCallbackId = call.callbackId
            self.isBackgroundMode = background

            // Read options
            let distanceFilter = call.getDouble("distanceFilter") ?? 0
            self.maxTrackingDurationMs = call.getDouble("maxTrackingDurationMs") ?? 43200000

            // Save distance filter for potential restore
            UserDefaults.standard.set(distanceFilter, forKey: Self.keyDistanceFilter)

            self.configureLocationManager(manager, call: call, background: background)

            if background {
                // Save tracking state for persistence
                self.saveTrackingState()

                // Start significant location change monitoring (survives app termination)
                manager.startMonitoringSignificantLocationChanges()

                // Start auto-stop timer
                self.startAutoStopTimer(remainingMs: self.maxTrackingDurationMs)

                // Start headless HTTP posting timer
                self.startPostTimer()
            }

            if call.getBool("requestPermissions") != false {
                if self.handlePermissions(manager, background: background) {
                    return
                }
            }
            return self.startUpdatingLocation()
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.stopAllTracking()

            if let callbackId = self.activeCallbackId {
                if let savedCall = self.bridge?.savedCall(withID: callbackId) {
                    self.bridge?.releaseCall(savedCall)
                }
                self.activeCallbackId = nil
            }
            return call.resolve()
        }
    }

    private func stopAllTracking() {
        stopUpdatingLocation()

        locationManager?.stopMonitoringSignificantLocationChanges()
        locationManager?.delegate = nil
        locationManager = nil
        created = nil

        stopPostTimer()
        stopAutoStopTimer()
        clearTrackingState()
    }

    // MARK: - Configure (Headless Mode)

    @objc func configure(_ call: CAPPluginCall) {
        let defaults = UserDefaults.standard
        let prefix = Self.prefsPrefix

        if let serverUrl = call.getString("serverUrl") {
            defaults.set(serverUrl, forKey: "\(prefix)server_url")
        }
        if let authToken = call.getString("authToken") {
            defaults.set(authToken, forKey: "\(prefix)auth_token")
        }
        if let employeeId = call.getString("employeeId") {
            defaults.set(employeeId, forKey: "\(prefix)employee_id")
        }
        if let tenantId = call.getString("tenantId") {
            defaults.set(tenantId, forKey: "\(prefix)tenant_id")
        }
        if let batchSize = call.getInt("batchSize") {
            defaults.set(batchSize, forKey: "\(prefix)batch_size")
        }
        if let postIntervalMs = call.getInt("postIntervalMs") {
            defaults.set(postIntervalMs, forKey: "\(prefix)post_interval")
        }

        call.resolve()
    }

    // MARK: - Buffered Locations

    @objc func getBufferedLocations(_ call: CAPPluginCall) {
        guard let buffer = locationBuffer else {
            return call.resolve(["locations": []])
        }
        let all = buffer.getAll()
        call.resolve(["locations": all])
    }

    @objc func clearBufferedLocations(_ call: CAPPluginCall) {
        locationBuffer?.clearAll()
        call.resolve()
    }

    // MARK: - Timers

    private func startPostTimer() {
        stopPostTimer()
        let defaults = UserDefaults.standard
        let intervalMs = defaults.integer(forKey: "\(Self.prefsPrefix)post_interval")
        let interval = intervalMs > 0 ? TimeInterval(intervalMs) / 1000.0 : 60.0

        postTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                guard let self = self, let buffer = self.locationBuffer, let poster = self.httpPoster else { return }
                poster.postBatch(buffer)
            }
        }
    }

    private func stopPostTimer() {
        postTimer?.invalidate()
        postTimer = nil
    }

    private func startAutoStopTimer(remainingMs: Double) {
        stopAutoStopTimer()
        let remainingSeconds = max(remainingMs / 1000.0, 1.0)

        autoStopTimer = Timer.scheduledTimer(withTimeInterval: remainingSeconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                print("[BackgroundGeolocation] Auto-stop: max tracking duration reached")
                self?.stopAllTracking()
            }
        }
    }

    private func stopAutoStopTimer() {
        autoStopTimer?.invalidate()
        autoStopTimer = nil
    }

    // MARK: - Location Manager Configuration

    private func configureLocationManager(_ manager: CLLocationManager, call: CAPPluginCall, background: Bool) {
        let externalPower = [
            .full,
            .charging
        ].contains(UIDevice.current.batteryState)
        manager.desiredAccuracy = (
            externalPower
                ? kCLLocationAccuracyBestForNavigation
                : kCLLocationAccuracyBest
        )
        var distanceFilter = call.getDouble("distanceFilter")
        if distanceFilter == nil || distanceFilter == 0 {
            distanceFilter = kCLDistanceFilterNone
        }
        manager.distanceFilter = distanceFilter ?? kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = background
        manager.showsBackgroundLocationIndicator = background
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .otherNavigation // Reduces iOS throttling in background
    }

    private func handlePermissions(_ manager: CLLocationManager, background: Bool) -> Bool {
        let status = manager.authorizationStatus
        if [
            .notDetermined,
            .denied,
            .restricted
        ].contains(status) {
            if background {
                manager.requestAlwaysAuthorization()
            } else {
                manager.requestWhenInUseAuthorization()
            }
            return true
        }
        if background && status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        return false
    }

    // MARK: - Open Settings

    @objc func openSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let settingsUrl = URL(
                string: UIApplication.openSettingsURLString
            ) else {
                return call.reject("No link to settings available")
            }

            if UIApplication.shared.canOpenURL(settingsUrl) {
                UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                    if success {
                        return call.resolve()
                    } else {
                        return call.reject("Failed to open settings")
                    }
                })
            } else {
                return call.reject("Cannot open settings")
            }
        }
    }

    // MARK: - Planned Route

    @objc func setPlannedRoute(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            guard let soundFile = call.getString("soundFile") else {
                call.reject("Sound file is required")
                return
            }

            let routeArray = call.getArray("route", Any.self) ?? []
            var route: [[Double]] = []

            for routePoint in routeArray {
                if let pointArray = routePoint as? [Double], pointArray.count == 2 {
                    route.append(pointArray)
                }
            }

            let distance = call.getDouble("distance") ?? 50.0

            let assetPath = "public/" + soundFile
            let assetPathSplit = assetPath.components(separatedBy: ".")
            guard let url = Bundle.main.url(forResource: assetPathSplit[0], withExtension: assetPathSplit[1]) else {
                call.reject("Sound file not found: \(assetPath)")
                return
            }

            do {
                self.audioPlayer?.stop()
                self.audioPlayer = nil
                self.audioPlayer = try AVAudioPlayer(contentsOf: url)

                self.plannedRoute = route
                self.distanceThreshold = distance
                self.isOffRoute = true

                call.resolve()
            } catch {
                call.reject("Could not load the sound file: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Location Updates

    private func startUpdatingLocation() {
        if !isUpdatingLocation, let manager = locationManager {
            manager.startUpdatingLocation()
            isUpdatingLocation = true
        }
    }

    private func stopUpdatingLocation() {
        if isUpdatingLocation, let manager = locationManager {
            manager.stopUpdatingLocation()
            isUpdatingLocation = false
        }
    }

    private func isLocationValid(_ location: CLLocation) -> Bool {
        guard let created = created else { return allowStale }
        return (
            allowStale ||
                location.timestamp >= created
        )
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        guard let callbackId = activeCallbackId,
              let call = self.bridge?.savedCall(withID: callbackId) else {
            return
        }

        if let clErr = error as? CLError {
            if clErr.code == .locationUnknown {
                return
            } else if clErr.code == .denied {
                stopUpdatingLocation()
                return call.reject(
                    "Permission denied.",
                    "NOT_AUTHORIZED"
                )
            }
        }
        return call.reject(error.localizedDescription, nil, error)
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }

        // Always buffer location in background mode
        if isBackgroundMode {
            locationBuffer?.insert(location)
            locationsSinceLastPost += 1

            // Post buffered locations using beginBackgroundTask for reliable background execution
            if locationsSinceLastPost >= postBatchThreshold {
                locationsSinceLastPost = 0
                postBufferedLocationsInBackground()
            }
        }

        // Send to JS callback if available
        if let callbackId = activeCallbackId,
           let call = self.bridge?.savedCall(withID: callbackId) {
            if isLocationValid(location) {
                checkRouteDeviation(location)
                call.resolve(formatLocation(location))
            }
        }
    }

    /// Post buffered locations using beginBackgroundTask for ~30s of guaranteed execution time
    private func postBufferedLocationsInBackground() {
        guard let buffer = locationBuffer, let poster = httpPoster else { return }

        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "LocationPost") {
            // Expiration handler — clean up
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }

        DispatchQueue.global(qos: .utility).async {
            poster.postBatch(buffer)
            DispatchQueue.main.async {
                if bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                    bgTaskId = .invalid
                }
            }
        }
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        if status != .notDetermined {
            startUpdatingLocation()
        }
    }

    // MARK: - Route Deviation

    private func toRadians(_ degrees: Double) -> Double {
        return degrees * Double.pi / 180.0
    }

    private func haversine(_ point1: [Double], _ point2: [Double]) -> Double {
        let lon1 = point1[0]
        let lat1 = point1[1]
        let lon2 = point2[0]
        let lat2 = point2[1]

        let dLat = toRadians(lat2 - lat1)
        let dLon = toRadians(lon2 - lon1)

        let aaa = sin(dLat / 2) * sin(dLat / 2) +
            cos(toRadians(lat1)) * cos(toRadians(lat2)) *
            sin(dLon / 2) * sin(dLon / 2)

        let ccc = 2 * atan2(sqrt(aaa), sqrt(1 - aaa))

        return BackgroundGeolocation.earthRadiusMeters * ccc
    }

    private func distancePointToLineSegment(_ point: [Double], _ lineStart: [Double], _ lineEnd: [Double]) -> Double {
        let distAB = haversine(point, lineStart)
        let distAC = haversine(point, lineEnd)
        let distBC = haversine(lineStart, lineEnd)

        if distBC == 0 {
            return distAB
        }

        let epsilon = Double.ulpOfOne
        let cosB = (pow(distAB, 2) + pow(distBC, 2) - pow(distAC, 2)) / (2 * distAB * distBC + epsilon)
        if cosB < 0 {
            return distAB
        }

        let cosC = (pow(distAC, 2) + pow(distBC, 2) - pow(distAB, 2)) / (2 * distAC * distBC + epsilon)
        if cosC < 0 {
            return distAC
        }

        let semi = (distAB + distAC + distBC) / 2
        let area = sqrt(max(0, semi * (semi - distAB) * (semi - distAC) * (semi - distBC)))
        return (2 * area) / (distBC + epsilon)
    }

    private func distancePointToRoute(_ point: [Double]) -> Double {
        if plannedRoute.count < 2 {
            if plannedRoute.count == 1 {
                return haversine(point, plannedRoute[0])
            }
            return Double.infinity
        }

        var minDistance = Double.infinity

        for pointIndex in 0..<(plannedRoute.count - 1) {
            let lineStart = plannedRoute[pointIndex]
            let lineEnd = plannedRoute[pointIndex + 1]
            let distance = distancePointToLineSegment(point, lineStart, lineEnd)
            if distance < minDistance {
                minDistance = distance
            }
        }

        return minDistance
    }

    private func checkRouteDeviation(_ location: CLLocation) {
        guard audioPlayer != nil && plannedRoute.count > 0 else { return }

        let currentPoint = [location.coordinate.longitude, location.coordinate.latitude]
        let offRoute = distancePointToRoute(currentPoint) > distanceThreshold

        if offRoute && !isOffRoute {
            audioPlayer?.play()
        }

        isOffRoute = offRoute
    }

    // MARK: - Plugin Version

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve(["version": self.pluginVersion])
    }

}
