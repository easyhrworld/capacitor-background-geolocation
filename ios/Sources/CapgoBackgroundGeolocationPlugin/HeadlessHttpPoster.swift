import Foundation

/// Posts buffered location batches to a server endpoint using native URLSession.
/// Mirrors the Android HeadlessHttpPoster.java implementation.
class HeadlessHttpPoster {

    private static let prefsPrefix = "bg_geo_"

    /// Post a batch of unsynced locations to the configured server.
    /// Reads configuration from UserDefaults.
    func postBatch(_ locationBuffer: LocationBuffer) {
        let defaults = UserDefaults.standard
        let serverUrl = defaults.string(forKey: "\(Self.prefsPrefix)server_url") ?? ""
        let authToken = defaults.string(forKey: "\(Self.prefsPrefix)auth_token") ?? ""
        let employeeId = defaults.string(forKey: "\(Self.prefsPrefix)employee_id") ?? ""
        let tenantId = defaults.string(forKey: "\(Self.prefsPrefix)tenant_id") ?? ""
        let batchSize = defaults.integer(forKey: "\(Self.prefsPrefix)batch_size")
        let effectiveBatchSize = batchSize > 0 ? batchSize : 20

        guard !serverUrl.isEmpty, !authToken.isEmpty else {
            print("[BackgroundGeolocation] Headless posting not configured, skipping")
            return
        }

        guard let url = URL(string: serverUrl) else {
            print("[BackgroundGeolocation] Invalid server URL: \(serverUrl)")
            return
        }

        let batch = locationBuffer.getUnsyncedBatch(effectiveBatchSize)
        guard !batch.isEmpty else { return }

        // Build payload matching Android format
        var locations: [[String: Any]] = []
        var ids: [Int64] = []

        for row in batch {
            if let id = row["id"] as? Int64 {
                ids.append(id)
            }
            var loc: [String: Any] = [:]
            loc["lat"] = row["lat"]
            loc["lng"] = row["lng"]
            loc["accuracy"] = row["accuracy"]
            loc["speed"] = row["speed"]
            loc["bearing"] = row["bearing"]
            loc["altitude"] = row["altitude"]
            loc["timestamp"] = row["timestamp"]
            locations.append(loc)
        }

        let payload: [String: Any] = [
            "employeeId": employeeId,
            "tenantId": tenantId,
            "locations": locations,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            print("[BackgroundGeolocation] Failed to serialize payload")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = body

        // Synchronous post on background thread (called from timer)
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }

            if let error = error {
                print("[BackgroundGeolocation] Headless HTTP post error: \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode) {
                print("[BackgroundGeolocation] Headless post successful: \(batch.count) locations")
                success = true
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[BackgroundGeolocation] Headless post failed with HTTP \(code)")
            }
        }
        task.resume()
        semaphore.wait()

        if success {
            locationBuffer.markSynced(ids)
            locationBuffer.deleteSynced()
        }
    }
}
