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
        "mockLocationStatus": locationEvidenceStatus(location),
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
    private let pluginVersion: String = "8.4.5"
    public let identifier = "BackgroundGeolocationPlugin"
    public let jsName = "BackgroundGeolocation"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getCurrentLocation", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnCallback),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openSettings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPlannedRoute", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPluginVersion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "configure", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBufferedLocations", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearBufferedLocations", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAuthorizationStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setupGeofencing", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "addGeofence", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeGeofence", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeAllGeofences", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getMonitoredGeofences", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateHeaders", returnType: CAPPluginReturnPromise),
    ]

    private var locationSnapshots: [String: LocationSnapshot] = [:]
    private var geofenceLocationManager: CLLocationManager?
    private var activeCallbackId: String?
    private var allowStale: Bool = false
    private var created: Date?

    // Route deviation
    private var audioPlayer: AVAudioPlayer?
    private var plannedRoute: [[Double]] = []
    private var isOffRoute: Bool = true
    private var distanceThreshold: Double = 50.0 // Default distance threshold in meters
    private var geofenceBackendUrl: URL?
    private var geofenceNotifyOnEntry: Bool = true
    private var geofenceNotifyOnExit: Bool = true
    private var geofencePayload: [String: Any] = [:]
    private var pendingGeofenceSetupCall: CAPPluginCall?
    private var pendingGeofenceSetupTimeout: DispatchWorkItem?
    private var pendingPermissionRequestCall: CAPPluginCall?
    private var pendingPermissionRequestTimeout: DispatchWorkItem?
    private var pendingGeofenceAddCalls: [String: CAPPluginCall] = [:]
    private var pendingGeofenceRegions: [String: (region: CLCircularRegion, payload: [String: Any])] = [:]
    private var lastGeofenceTransition: [String: String] = [:]
    // When set (via the "url" start option), each valid location is also POSTed
    // as JSON directly from native code, independently of the WebView.
    private var locationBackendUrl: URL?
    private var locationHeaders: [String: String] = [:]
    private var geofenceHeaders: [String: String] = [:]
    private var minIntervalMs: Double = 0
    private var lastPostedLocationTime: Date?

    private let geofenceUrlKey = "CapgoBackgroundGeolocation.geofence.url"
    private let geofenceHeadersKey = "CapgoBackgroundGeolocation.geofence.headers"
    private let geofenceNotifyOnEntryKey = "CapgoBackgroundGeolocation.geofence.notifyOnEntry"
    private let geofenceNotifyOnExitKey = "CapgoBackgroundGeolocation.geofence.notifyOnExit"
    private let geofencePayloadKey = "CapgoBackgroundGeolocation.geofence.payload"
    private let geofenceRegionPrefix = "CapgoBackgroundGeolocation.geofence.region."

    // Earth radius in meters for distance calculations
    private static let earthRadiusMeters: Double = 6371000.0

    @objc override public func load() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Restore tracking if app was relaunched by significant location change
        LocationTracker.shared.restoreIfNeeded()
        restoreGeofenceConfiguration()
        DispatchQueue.main.async {
            _ = self.ensureGeofenceLocationManager()
        }
    }

    @objc func getCurrentLocation(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let snapshot = LocationSnapshot { [weak self] result in
                self?.locationSnapshots.removeValue(forKey: call.callbackId)
                switch result {
                case .success(let location): call.resolve(formatLocation(location))
                case .failure(let error): call.reject(error.localizedDescription, "LOCATION_ERROR")
                }
            }
            self.locationSnapshots[call.callbackId] = snapshot
            snapshot.start()
        }
    }

    // MARK: - Start / Stop

    @objc func start(_ call: CAPPluginCall) {
        call.keepAlive = true

        DispatchQueue.main.async {
            let tracker = LocationTracker.shared

            if tracker.isTracking {
                return call.reject("Location tracking already started", "ALREADY_STARTED")
            }
            // Optional native delivery endpoint (same validation as setupGeofencing).
            if let urlString = call.getString("url"), !urlString.isEmpty {
                guard let url = URL(string: urlString),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) else {
                    return call.reject("Given url is not valid")
                }
                self.locationBackendUrl = url
            } else {
                self.locationBackendUrl = nil
            }
            self.locationHeaders = self.stringHeaders(from: call.getObject("headers"))
            self.minIntervalMs = max(0, call.getDouble("minIntervalMs") ?? 0)
            self.lastPostedLocationTime = nil

            self.allowStale = call.getBool("stale") ?? false
            self.activeCallbackId = call.callbackId
            self.created = Date()

            let background = call.getString("backgroundMessage") != nil
            let distanceFilter = call.getDouble("distanceFilter") ?? 0
            let maxDuration = call.getDouble("maxTrackingDurationMs") ?? 43200000
            let requestPerms = call.getBool("requestPermissions") != false

            NSLog("[BackgroundGeolocation] Plugin start() called. background=%d", background ? 1 : 0)

            // Native delivery and route handling run independently of the saved JS callback.
            tracker.onLocationUpdate = { [weak self] location in
                guard let self = self, self.isLocationValid(location) else { return }
                self.postLocation(location)
                self.checkRouteDeviation(location)
                guard let callbackId = self.activeCallbackId,
                      let savedCall = self.bridge?.savedCall(withID: callbackId) else { return }
                savedCall.resolve(formatLocation(location))
            }
            tracker.onLocationError = { [weak self] error in
                guard let self = self, let callbackId = self.activeCallbackId,
                      let savedCall = self.bridge?.savedCall(withID: callbackId) else { return }
                let code = (error as? CLError)?.code == .denied ? "NOT_AUTHORIZED" : "LOCATION_ERROR"
                savedCall.reject(error.localizedDescription, code, error)
            }
            tracker.start(
                distanceFilter: distanceFilter,
                maxDuration: maxDuration,
                requestPermissions: requestPerms,
                background: background
            )
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            LocationTracker.shared.stop()
            LocationTracker.shared.onLocationUpdate = nil
            LocationTracker.shared.onLocationError = nil
            self.locationBackendUrl = nil
            self.locationHeaders = [:]
            self.minIntervalMs = 0
            self.lastPostedLocationTime = nil

            if let callbackId = self.activeCallbackId {
                if let savedCall = self.bridge?.savedCall(withID: callbackId) {
                    self.bridge?.releaseCall(savedCall)
                }
                self.activeCallbackId = nil
            }
            self.created = nil
            return call.resolve()
        }
    }

    // MARK: - Configure (Headless Mode)

    @objc func configure(_ call: CAPPluginCall) {
        let defaults = UserDefaults.standard
        objc_sync_enter(defaults)
        defer { objc_sync_exit(defaults) }
        let prefix = "bg_geo_"

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

        NSLog("[BackgroundGeolocation] configure() called. serverUrl=%@", call.getString("serverUrl") ?? "nil")
        call.resolve()
    }

    // MARK: - Buffered Locations

    @objc func getBufferedLocations(_ call: CAPPluginCall) {
        let all = LocationTracker.shared.locationBuffer.getAll()
        call.resolve(["locations": all])
    }

    @objc func clearBufferedLocations(_ call: CAPPluginCall) {
        LocationTracker.shared.locationBuffer.clearAll()
        call.resolve()
    }

    // MARK: - Open Settings

    @objc func updateHeaders(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let headers = self.stringHeaders(from: call.getObject("headers"))
            self.locationHeaders = headers
            self.geofenceHeaders = headers
            self.persistGeofenceConfiguration()
            call.resolve()
        }
    }

    @objc func openSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                return call.reject("No link to settings available")
            }
            if UIApplication.shared.canOpenURL(settingsUrl) {
                UIApplication.shared.open(settingsUrl) { success in
                    success ? call.resolve() : call.reject("Failed to open settings")
                }
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

    private func requestGeofenceAlwaysAuthorization(_ call: CAPPluginCall, manager: CLLocationManager, status: CLAuthorizationStatus) {
        pendingGeofenceSetupCall = call
        pendingGeofenceSetupTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, let pendingCall = self.pendingGeofenceSetupCall else { return }
            self.pendingGeofenceSetupCall = nil
            self.pendingGeofenceSetupTimeout = nil
            if manager.authorizationStatus == .authorizedAlways {
                pendingCall.resolve()
            } else {
                pendingCall.reject(
                    "Always location permission is required for geofencing",
                    "NOT_AUTHORIZED"
                )
            }
        }
        pendingGeofenceSetupTimeout = timeout
        manager.requestAlwaysAuthorization()
        if status == .authorizedWhenInUse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        }
    }

    @objc func setupGeofencing(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if self.pendingGeofenceSetupCall != nil {
                return call.reject("A geofence permission request is already in progress", "PERMISSION_REQUEST_IN_PROGRESS")
            }
            guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
                return call.reject("Geofencing is not available on this device", "NOT_AVAILABLE")
            }
            var backendUrl: URL?
            if let urlString = call.getString("url"), !urlString.isEmpty {
                guard let url = URL(string: urlString),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) else {
                    return call.reject("Given url is not valid")
                }
                backendUrl = url
            }
            let payload = call.getObject("payload") ?? [:]
            guard JSONSerialization.isValidJSONObject(payload) else {
                return call.reject("Payload must be valid JSON")
            }

            self.geofenceBackendUrl = backendUrl
            self.geofenceHeaders = self.stringHeaders(from: call.getObject("headers"))
            self.geofenceNotifyOnEntry = call.getBool("notifyOnEntry") ?? true
            self.geofenceNotifyOnExit = call.getBool("notifyOnExit") ?? true
            self.geofencePayload = payload
            self.persistGeofenceConfiguration()

            let manager = self.ensureGeofenceLocationManager()
            let status = manager.authorizationStatus
            if status == .authorizedAlways {
                return call.resolve()
            }
            if call.getBool("requestPermissions") == false {
                return call.reject("Always location permission is required for geofencing", "NOT_AUTHORIZED")
            }
            if [.denied, .restricted].contains(status) {
                return call.reject("Always location permission is required for geofencing", "NOT_AUTHORIZED")
            }
            self.requestGeofenceAlwaysAuthorization(call, manager: manager, status: status)
        }
    }

    @objc func addGeofence(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let manager = self.ensureGeofenceLocationManager()
            guard self.geofenceAvailable(manager) else {
                return call.reject("Always location permission is required for geofencing", "NOT_AUTHORIZED")
            }
            guard let latitude = call.getDouble("latitude") else {
                return call.reject("Latitude is required")
            }
            guard let longitude = call.getDouble("longitude") else {
                return call.reject("Longitude is required")
            }
            guard let identifier = call.getString("identifier"), !identifier.isEmpty else {
                return call.reject("Identifier is required")
            }
            let radius = call.getDouble("radius") ?? 50.0
            guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
                return call.reject("Invalid latitude or longitude")
            }
            guard radius > 0 else {
                return call.reject("Radius must be greater than 0")
            }
            let maximumDistance = manager.maximumRegionMonitoringDistance
            guard maximumDistance <= 0 || radius <= maximumDistance else {
                return call.reject("Radius exceeds the maximum supported region monitoring distance")
            }
            let notifyOnEntry = call.getBool("notifyOnEntry") ?? self.geofenceNotifyOnEntry
            let notifyOnExit = call.getBool("notifyOnExit") ?? self.geofenceNotifyOnExit
            guard notifyOnEntry || notifyOnExit else {
                return call.reject("At least one transition must be enabled")
            }
            let payload = call.getObject("payload") ?? [:]
            guard JSONSerialization.isValidJSONObject(payload) else {
                return call.reject("Payload must be valid JSON")
            }

            guard self.pendingGeofenceAddCalls[identifier] == nil else {
                return call.reject("A geofence with that identifier is already being added", "PENDING")
            }

            let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let region = CLCircularRegion(center: center, radius: radius, identifier: identifier)
            region.notifyOnEntry = notifyOnEntry
            region.notifyOnExit = notifyOnExit
            self.pendingGeofenceAddCalls[identifier] = call
            self.pendingGeofenceRegions[identifier] = (region, payload)
            manager.startMonitoring(for: region)
        }
    }

    @objc func removeGeofence(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let identifier = call.getString("identifier"), !identifier.isEmpty else {
                return call.reject("Identifier is required")
            }
            let manager = self.ensureGeofenceLocationManager()
            if let pending = self.pendingGeofenceRegions.removeValue(forKey: identifier) {
                manager.stopMonitoring(for: pending.region)
                self.pendingGeofenceAddCalls.removeValue(forKey: identifier)?.reject(
                    "Geofence was removed before monitoring started",
                    "CANCELLED"
                )
                self.removePersistedGeofenceRegion(identifier)
                self.lastGeofenceTransition.removeValue(forKey: identifier)
                return call.resolve()
            }
            guard self.persistedGeofenceRegionIds().contains(identifier) else {
                return call.reject("Could not find a region with that identifier", "NOT_FOUND")
            }
            guard let region = manager.monitoredRegions.first(where: { $0.identifier == identifier && $0 is CLCircularRegion }) else {
                self.pendingGeofenceAddCalls.removeValue(forKey: identifier)?.reject("Geofence was removed before monitoring started", "CANCELLED")
                self.pendingGeofenceRegions.removeValue(forKey: identifier)
                self.removePersistedGeofenceRegion(identifier)
                self.lastGeofenceTransition.removeValue(forKey: identifier)
                return call.resolve()
            }
            manager.stopMonitoring(for: region)
            self.pendingGeofenceAddCalls.removeValue(forKey: identifier)?.reject("Geofence was removed before monitoring started", "CANCELLED")
            self.pendingGeofenceRegions.removeValue(forKey: identifier)
            self.removePersistedGeofenceRegion(identifier)
            self.lastGeofenceTransition.removeValue(forKey: identifier)
            call.resolve()
        }
    }

    @objc func removeAllGeofences(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let manager = self.ensureGeofenceLocationManager()
            let identifiers = self.persistedGeofenceRegionIds()
            for region in manager.monitoredRegions where region is CLCircularRegion && identifiers.contains(region.identifier) {
                manager.stopMonitoring(for: region)
            }
            for identifier in identifiers {
                self.removePersistedGeofenceRegion(identifier)
                self.lastGeofenceTransition.removeValue(forKey: identifier)
            }
            for (_, pendingCall) in self.pendingGeofenceAddCalls {
                pendingCall.reject("Geofences were removed before monitoring started", "CANCELLED")
            }
            self.pendingGeofenceAddCalls.removeAll()
            self.pendingGeofenceRegions.removeAll()
            call.resolve()
        }
    }

    @objc func getMonitoredGeofences(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let manager = self.ensureGeofenceLocationManager()
            let identifiers = self.persistedGeofenceRegionIds()
            let regions = manager.monitoredRegions.compactMap { region -> String? in
                region is CLCircularRegion && identifiers.contains(region.identifier) ? region.identifier : nil
            }.sorted()
            call.resolve(["regions": regions])
        }
    }

    private func ensureGeofenceLocationManager() -> CLLocationManager {
        if let manager = geofenceLocationManager {
            return manager
        }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        geofenceLocationManager = manager
        return manager
    }

    private func geofenceAvailable(_ manager: CLLocationManager) -> Bool {
        CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) && manager.authorizationStatus == .authorizedAlways
    }

    private func persistGeofenceConfiguration() {
        let defaults = UserDefaults.standard
        defaults.set(geofenceBackendUrl?.absoluteString, forKey: geofenceUrlKey)
        defaults.set(geofenceNotifyOnEntry, forKey: geofenceNotifyOnEntryKey)
        defaults.set(geofenceNotifyOnExit, forKey: geofenceNotifyOnExitKey)
        if JSONSerialization.isValidJSONObject(geofencePayload),
           let data = try? JSONSerialization.data(withJSONObject: geofencePayload) {
            defaults.set(data, forKey: geofencePayloadKey)
        } else {
            defaults.removeObject(forKey: geofencePayloadKey)
        }
        if JSONSerialization.isValidJSONObject(geofenceHeaders),
           let data = try? JSONSerialization.data(withJSONObject: geofenceHeaders) {
            defaults.set(data, forKey: geofenceHeadersKey)
        } else {
            defaults.removeObject(forKey: geofenceHeadersKey)
        }
    }

    private func restoreGeofenceConfiguration() {
        let defaults = UserDefaults.standard
        if let urlString = defaults.string(forKey: geofenceUrlKey), !urlString.isEmpty {
            geofenceBackendUrl = URL(string: urlString)
        }
        if defaults.object(forKey: geofenceNotifyOnEntryKey) != nil {
            geofenceNotifyOnEntry = defaults.bool(forKey: geofenceNotifyOnEntryKey)
        }
        if defaults.object(forKey: geofenceNotifyOnExitKey) != nil {
            geofenceNotifyOnExit = defaults.bool(forKey: geofenceNotifyOnExitKey)
        }
        if let data = defaults.data(forKey: geofencePayloadKey),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            geofencePayload = payload
        }
        if let data = defaults.data(forKey: geofenceHeadersKey),
           let headers = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            geofenceHeaders = stringHeaders(from: headers)
        }
    }

    private func persistGeofenceRegion(_ region: CLCircularRegion, payload: [String: Any]) {
        let data: [String: Any] = [
            "latitude": region.center.latitude,
            "longitude": region.center.longitude,
            "radius": region.radius,
            "payload": payload
        ]
        if JSONSerialization.isValidJSONObject(data),
           let encoded = try? JSONSerialization.data(withJSONObject: data) {
            UserDefaults.standard.set(encoded, forKey: geofenceRegionPrefix + region.identifier)
        }
    }

    private func persistedGeofenceRegion(_ identifier: String) -> [String: Any] {
        guard let data = UserDefaults.standard.data(forKey: geofenceRegionPrefix + identifier),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return decoded
    }

    private func removePersistedGeofenceRegion(_ identifier: String) {
        UserDefaults.standard.removeObject(forKey: geofenceRegionPrefix + identifier)
    }

    private func persistedGeofenceRegionIds() -> Set<String> {
        Set(UserDefaults.standard.dictionaryRepresentation().keys.compactMap { key in
            guard key.hasPrefix(geofenceRegionPrefix) else { return nil }
            return String(key.dropFirst(geofenceRegionPrefix.count))
        })
    }

    private func geofenceTransitionData(for region: CLRegion, enter: Bool) -> [String: Any] {
        let persistedRegion = persistedGeofenceRegion(region.identifier)
        let regionPayload = persistedRegion["payload"] as? [String: Any] ?? [:]
        var payload = geofencePayload
        for (key, value) in regionPayload {
            payload[key] = value
        }

        var data = payload
        data["identifier"] = region.identifier
        data["transition"] = enter ? "enter" : "exit"
        data["enter"] = enter
        if let circularRegion = region as? CLCircularRegion {
            data["latitude"] = circularRegion.center.latitude
            data["longitude"] = circularRegion.center.longitude
            data["radius"] = circularRegion.radius
        } else {
            data["latitude"] = persistedRegion["latitude"]
            data["longitude"] = persistedRegion["longitude"]
            data["radius"] = persistedRegion["radius"]
        }
        data["payload"] = payload
        return data
    }

    private func handleGeofenceTransition(for region: CLRegion, enter: Bool) {
        if let circularRegion = region as? CLCircularRegion {
            if enter && !circularRegion.notifyOnEntry {
                return
            }
            if !enter && !circularRegion.notifyOnExit {
                return
            }
        }

        let transition = enter ? "enter" : "exit"
        if lastGeofenceTransition[region.identifier] == transition {
            return
        }
        lastGeofenceTransition[region.identifier] = transition

        let data = geofenceTransitionData(for: region, enter: enter)
        notifyListeners("geofenceTransition", data: data, retainUntilConsumed: true)
        postGeofenceTransition(data)
    }

    private func postGeofenceTransition(_ data: [String: Any]) {
        guard let backendUrl = geofenceBackendUrl,
              JSONSerialization.isValidJSONObject(data),
              let body = try? JSONSerialization.data(withJSONObject: data) else {
            return
        }
        postJson(body, to: backendUrl, headers: geofenceHeaders, taskName: "CapgoGeofenceTransition")
    }

    // Like formatLocation, but safe for JSONSerialization: the bridge's
    // optional-based null sentinel cannot be serialized, so missing values are
    // encoded as NSNull instead. Includes "source": "native" so the server can
    // distinguish native POSTs from updates forwarded by the JavaScript layer.
    func locationPayload(_ location: CLLocation) -> [String: Any] {
        var simulated = false
        if #available(iOS 15, *) {
            if let sourceInfo = location.sourceInformation {
                simulated = sourceInfo.isSimulatedBySoftware
            }
        }
        var data: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "altitude": location.altitude,
            "altitudeAccuracy": location.verticalAccuracy,
            "simulated": simulated,
            "mockLocationStatus": locationEvidenceStatus(location),
            "time": NSNumber(
                value: Int(
                    location.timestamp.timeIntervalSince1970 * 1000
                )
            ),
            "source": "native"
        ]
        if location.speed < 0 {
            data["speed"] = NSNull()
        } else {
            data["speed"] = location.speed
        }
        if location.course < 0 {
            data["bearing"] = NSNull()
        } else {
            data["bearing"] = location.course
        }
        return data
    }

    // Delivers a location to the configured URL from native code, in parallel
    // with (and independently of) the JavaScript callback.
    private func shouldPostLocation(_ location: CLLocation) -> Bool {
        guard minIntervalMs > 0 else { return true }
        guard let lastPostedLocationTime else { return true }
        if location.timestamp < lastPostedLocationTime {
            return true
        }
        let elapsedMs = location.timestamp.timeIntervalSince(lastPostedLocationTime) * 1000
        return elapsedMs >= minIntervalMs
    }

    private func postLocation(_ location: CLLocation) {
        guard let backendUrl = locationBackendUrl else { return }
        guard shouldPostLocation(location) else { return }
        let data = locationPayload(location)
        guard JSONSerialization.isValidJSONObject(data),
              let body = try? JSONSerialization.data(withJSONObject: data) else {
            return
        }
        lastPostedLocationTime = location.timestamp
        postJson(body, to: backendUrl, headers: locationHeaders, taskName: "CapgoLocationUpdate")
    }

    private func stringHeaders(from object: [String: Any]?) -> [String: String] {
        guard let object else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                headers[key] = string
            } else if let number = value as? NSNumber {
                headers[key] = number.stringValue
            } else {
                headers[key] = String(describing: value)
            }
        }
        return headers
    }

    private func postJson(_ body: Data, to url: URL, headers: [String: String], taskName: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: taskName) {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        URLSession.shared.dataTask(with: request) { _, _, _ in
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }.resume()
    }


    private func isLocationValid(_ location: CLLocation) -> Bool {
        guard let created = created else { return allowStale }
        return allowStale || location.timestamp >= created
    }

    // MARK: - Route Deviation

    private func toRadians(_ degrees: Double) -> Double {
        return degrees * Double.pi / 180.0
    }

    private func haversine(_ point1: [Double], _ point2: [Double]) -> Double {
        let lon1 = point1[0], lat1 = point1[1]
        let lon2 = point2[0], lat2 = point2[1]
        let dLat = toRadians(lat2 - lat1)
        let dLon = toRadians(lon2 - lon1)
        let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(toRadians(lat1)) * cos(toRadians(lat2)) *
            sin(dLon / 2) * sin(dLon / 2)
        return BackgroundGeolocation.earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private func distancePointToLineSegment(_ point: [Double], _ lineStart: [Double], _ lineEnd: [Double]) -> Double {
        let distAB = haversine(point, lineStart)
        let distAC = haversine(point, lineEnd)
        let distBC = haversine(lineStart, lineEnd)
        if distBC == 0 { return distAB }
        let epsilon = Double.ulpOfOne
        let cosB = (pow(distAB, 2) + pow(distBC, 2) - pow(distAC, 2)) / (2 * distAB * distBC + epsilon)
        if cosB < 0 { return distAB }
        let cosC = (pow(distAC, 2) + pow(distBC, 2) - pow(distAB, 2)) / (2 * distAC * distBC + epsilon)
        if cosC < 0 { return distAC }
        let semi = (distAB + distAC + distBC) / 2
        let area = sqrt(max(0, semi * (semi - distAB) * (semi - distAC) * (semi - distBC)))
        return (2 * area) / (distBC + epsilon)
    }

    private func distancePointToRoute(_ point: [Double]) -> Double {
        if plannedRoute.count < 2 {
            return plannedRoute.count == 1 ? haversine(point, plannedRoute[0]) : Double.infinity
        }
        var minDistance = Double.infinity
        for i in 0..<(plannedRoute.count - 1) {
            let d = distancePointToLineSegment(point, plannedRoute[i], plannedRoute[i + 1])
            if d < minDistance { minDistance = d }
        }
        return minDistance
    }

    private func checkRouteDeviation(_ location: CLLocation) {
        guard audioPlayer != nil && plannedRoute.count > 0 else { return }
        let currentPoint = [location.coordinate.longitude, location.coordinate.latitude]
        let offRoute = distancePointToRoute(currentPoint) > distanceThreshold
        if offRoute && !isOffRoute { audioPlayer?.play() }
        isOffRoute = offRoute
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        if pendingPermissionRequestCall != nil && status != .notDetermined {
            resolvePendingPermissionRequest()
        }

        if let pendingCall = pendingGeofenceSetupCall {
            if status == .authorizedAlways {
                pendingGeofenceSetupTimeout?.cancel()
                pendingGeofenceSetupTimeout = nil
                pendingGeofenceSetupCall = nil
                pendingCall.resolve()
            } else if status == .denied || status == .restricted || status == .authorizedWhenInUse {
                pendingGeofenceSetupTimeout?.cancel()
                pendingGeofenceSetupTimeout = nil
                pendingGeofenceSetupCall = nil
                pendingCall.reject("Always location permission is required for geofencing", "NOT_AUTHORIZED")
            }
        }

    }

    public func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        guard manager === geofenceLocationManager else { return }
        if let pending = pendingGeofenceRegions.removeValue(forKey: region.identifier) {
            persistGeofenceRegion(pending.region, payload: pending.payload)
            pendingGeofenceAddCalls.removeValue(forKey: region.identifier)?.resolve()
        }
        manager.requestState(for: region)
    }

    public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard manager === geofenceLocationManager, let region = region else { return }
        pendingGeofenceRegions.removeValue(forKey: region.identifier)
        removePersistedGeofenceRegion(region.identifier)
        pendingGeofenceAddCalls.removeValue(forKey: region.identifier)?.reject(
            "Could not start monitoring the geofence",
            "MONITORING_FAILED",
            error
        )
        let nsError = error as NSError
        notifyListeners(
            "geofenceError",
            data: [
                "identifier": region.identifier,
                "message": error.localizedDescription,
                "code": nsError.code,
                "domain": nsError.domain
            ],
            retainUntilConsumed: true
        )
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard manager === geofenceLocationManager, region is CLCircularRegion else { return }
        handleGeofenceTransition(for: region, enter: true)
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard manager === geofenceLocationManager, region is CLCircularRegion else { return }
        handleGeofenceTransition(for: region, enter: false)
    }

    public func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard manager === geofenceLocationManager, region is CLCircularRegion else { return }
        if state == .inside {
            handleGeofenceTransition(for: region, enter: true)
        }
    }

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve(self.permissionStatusDictionary())
        }
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if self.pendingPermissionRequestCall != nil {
                return call.reject("A permission request is already in progress", "PERMISSION_REQUEST_IN_PROGRESS")
            }

            let permissions = call.getArray("permissions", String.self) ?? [
                "location",
                "backgroundLocation",
                "notification"
            ]
            let requestBackground = permissions.contains("backgroundLocation")
            let requestLocation = permissions.contains("location") || requestBackground

            guard requestLocation || requestBackground else {
                return call.resolve(self.permissionStatusDictionary())
            }

            let manager = self.ensureGeofenceLocationManager()
            let status = manager.authorizationStatus

            if requestBackground {
                if status == .authorizedAlways {
                    return call.resolve(self.permissionStatusDictionary())
                }
                if [.denied, .restricted].contains(status) {
                    return call.resolve(self.permissionStatusDictionary())
                }
                self.beginPermissionRequest(call, manager: manager, requestAlways: true, status: status)
                return
            }

            if [.authorizedWhenInUse, .authorizedAlways].contains(status) {
                return call.resolve(self.permissionStatusDictionary())
            }
            if [.denied, .restricted].contains(status) {
                return call.resolve(self.permissionStatusDictionary())
            }
            self.beginPermissionRequest(call, manager: manager, requestAlways: false, status: status)
        }
    }

    private func beginPermissionRequest(
        _ call: CAPPluginCall,
        manager: CLLocationManager,
        requestAlways: Bool,
        status: CLAuthorizationStatus
    ) {
        pendingPermissionRequestCall = call
        pendingPermissionRequestTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, let pendingCall = self.pendingPermissionRequestCall else { return }
            self.pendingPermissionRequestCall = nil
            self.pendingPermissionRequestTimeout = nil
            pendingCall.resolve(self.permissionStatusDictionary())
        }
        pendingPermissionRequestTimeout = timeout
        if requestAlways {
            manager.requestAlwaysAuthorization()
            if status == .authorizedWhenInUse {
                DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
            }
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    private func resolvePendingPermissionRequest() {
        pendingPermissionRequestTimeout?.cancel()
        pendingPermissionRequestTimeout = nil
        guard let pendingCall = pendingPermissionRequestCall else { return }
        pendingPermissionRequestCall = nil
        pendingCall.resolve(permissionStatusDictionary())
    }

    private func permissionStatusDictionary() -> [String: Any] {
        let status = ensureGeofenceLocationManager().authorizationStatus
        var result: [String: Any] = [:]

        switch status {
        case .notDetermined:
            result["location"] = "prompt"
            result["backgroundLocation"] = "prompt"
        case .restricted, .denied:
            result["location"] = "denied"
            result["backgroundLocation"] = "denied"
        case .authorizedWhenInUse:
            result["location"] = "granted"
            result["backgroundLocation"] = "when_in_use"
        case .authorizedAlways:
            result["location"] = "granted"
            result["backgroundLocation"] = "granted"
        @unknown default:
            result["location"] = "prompt"
            result["backgroundLocation"] = "prompt"
        }

        return result
    }

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve(["version": self.pluginVersion])
    }

    // MARK: - Authorization Status

    @objc func getAuthorizationStatus(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let manager = CLLocationManager()
            let status: String
            switch manager.authorizationStatus {
            case .notDetermined:
                status = "notDetermined"
            case .authorizedWhenInUse:
                status = "whenInUse"
            case .authorizedAlways:
                status = "always"
            case .denied:
                status = "denied"
            case .restricted:
                status = "restricted"
            @unknown default:
                status = "notDetermined"
            }
            call.resolve(["status": status])
        }
    }
}
