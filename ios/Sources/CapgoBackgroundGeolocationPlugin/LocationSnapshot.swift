import CoreLocation
import Foundation

func locationEvidenceStatus(_ location: CLLocation) -> String {
    if #available(iOS 15, *), let source = location.sourceInformation {
        return source.isSimulatedBySoftware ? "mocked" : "not_detected"
    }
    return "unknown"
}

/// An independent foreground manager: taking a punch must not start or stop a shift's tracking.
final class LocationSnapshot: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let completion: (Result<CLLocation, Error>) -> Void
    private var startedAt = Date()
    private var timeout: DispatchWorkItem?
    private var finished = false

    init(completion: @escaping (Result<CLLocation, Error>) -> Void) {
        self.completion = completion
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled(),
              [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else {
            fail("Foreground location permission and location services are required.")
            return
        }
        startedAt = Date()
        let work = DispatchWorkItem { [weak self] in
            self?.fail("A fresh location was not available. Please retry.")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.timestamp >= startedAt,
              location.horizontalAccuracy >= 0 else { return }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        finish(.failure(error))
    }

    private func fail(_ message: String) {
        finish(.failure(NSError(domain: "LocationSnapshot", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: message])))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        manager.stopUpdatingLocation()
        manager.delegate = nil
        completion(result)
    }
}
