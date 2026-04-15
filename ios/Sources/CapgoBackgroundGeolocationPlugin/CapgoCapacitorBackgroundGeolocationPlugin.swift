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
public class BackgroundGeolocation: CAPPlugin, CAPBridgedPlugin {
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

    private var activeCallbackId: String?
    private var allowStale: Bool = false
    private var created: Date?

    // Route deviation
    private var audioPlayer: AVAudioPlayer?
    private var plannedRoute: [[Double]] = []
    private var isOffRoute: Bool = true
    private var distanceThreshold: Double = 50.0
    private static let earthRadiusMeters: Double = 6371000.0

    @objc override public func load() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Restore tracking if app was relaunched by significant location change
        LocationTracker.shared.restoreIfNeeded()
    }

    // MARK: - Start / Stop

    @objc func start(_ call: CAPPluginCall) {
        call.keepAlive = true

        DispatchQueue.main.async {
            let tracker = LocationTracker.shared

            if tracker.isTracking {
                return call.reject("Location tracking already started", "ALREADY_STARTED")
            }

            self.allowStale = call.getBool("stale") ?? false
            self.activeCallbackId = call.callbackId
            self.created = Date()

            let background = call.getString("backgroundMessage") != nil
            let distanceFilter = call.getDouble("distanceFilter") ?? 0
            let maxDuration = call.getDouble("maxTrackingDurationMs") ?? 43200000
            let requestPerms = call.getBool("requestPermissions") != false

            NSLog("[BackgroundGeolocation] Plugin start() called. background=%d", background ? 1 : 0)

            // Wire up location callback from tracker -> JS
            tracker.onLocationUpdate = { [weak self] location in
                guard let self = self,
                      let callbackId = self.activeCallbackId,
                      let savedCall = self.bridge?.savedCall(withID: callbackId) else { return }

                if self.isLocationValid(location) {
                    self.checkRouteDeviation(location)
                    savedCall.resolve(formatLocation(location))
                }
            }

            if background {
                tracker.start(
                    distanceFilter: distanceFilter,
                    maxDuration: maxDuration,
                    requestPermissions: requestPerms
                )
            } else {
                // Foreground-only: use tracker but don't persist state
                tracker.start(
                    distanceFilter: distanceFilter,
                    maxDuration: maxDuration,
                    requestPermissions: requestPerms
                )
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            LocationTracker.shared.stop()
            LocationTracker.shared.onLocationUpdate = nil

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

    // MARK: - Helpers

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

    // MARK: - Plugin Version

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve(["version": self.pluginVersion])
    }
}
