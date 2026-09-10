import type { PermissionState, PluginListenerHandle } from '@capacitor/core';

/**
 * Background location authorization on iOS distinguishes Always from While Using.
 * On Android this field uses standard {@link PermissionState} values.
 *
 * @since 8.0.43
 */
export type BackgroundLocationPermissionState = PermissionState | 'when_in_use' | 'always';

/**
 * Permission map returned by {@link BackgroundGeolocationPlugin.checkPermissions}
 * and {@link BackgroundGeolocationPlugin.requestPermissions}.
 *
 * Use `checkPermissions()` to read authorization without prompting. Use
 * `requestPermissions()` when you intentionally want to show the system dialog.
 * Pair `@capacitor/geolocation` for foreground location and this plugin for
 * background / Always authorization.
 *
 * @since 8.0.43
 */
export interface BackgroundGeolocationPermissionStatus {
  /**
   * Foreground location permission.
   *
   * @since 8.0.43
   */
  location?: PermissionState;
  /**
   * Background / Always location authorization.
   *
   * On iOS, `when_in_use` means While Using App only and `granted` / `always`
   * means Always authorization was granted.
   *
   * @since 8.0.43
   */
  backgroundLocation?: BackgroundLocationPermissionState;
  /**
   * Android foreground-service notification permission (API 33+).
   *
   * @since 8.0.43
   */
  notification?: PermissionState;
}

/**
 * Options for {@link BackgroundGeolocationPlugin.requestPermissions}.
 *
 * @since 8.0.43
 */
export interface RequestBackgroundGeolocationPermissionsOptions {
  /**
   * Subset of permissions to request. Defaults to all supported permissions.
   *
   * @since 8.0.43
   * @example ['backgroundLocation']
   */
  permissions?: ('location' | 'backgroundLocation' | 'notification')[];
}

/**
 * Configuration for headless mode — native HTTP posting of location
 * batches to a server endpoint without the WebView being alive.
 *
 * @since 1.0.0
 */
export interface HeadlessConfig {
  /**
   * The server URL to POST location batches to.
   *
   * @since 1.0.0
   * @example "https://api.example.com/attendance/geotrack"
   */
  serverUrl: string;
  /**
   * JWT Bearer token for authentication.
   *
   * @since 1.0.0
   */
  authToken: string;
  /**
   * Employee identifier included in the POST payload.
   *
   * @since 1.0.0
   */
  employeeId: string;
  /**
   * Tenant identifier included in the POST payload.
   *
   * @since 1.0.0
   */
  tenantId: string;
  /**
   * Additional HTTP headers to include in the POST request.
   *
   * @since 1.0.0
   */
  headers?: Record<string, string>;
  /**
   * Number of locations to include in each batch POST.
   *
   * @since 1.0.0
   * @default 20
   */
  batchSize?: number;
  /**
   * Interval in milliseconds between batch POST attempts.
   *
   * @since 1.0.0
   * @default 60000
   */
  postIntervalMs?: number;
}

/**
 * A buffered location record stored locally on the device.
 *
 * @since 1.0.0
 */
export interface BufferedLocation {
  lat: number;
  lng: number;
  accuracy: number;
  speed: number;
  bearing: number;
  altitude: number;
  timestamp: number;
  /** OS-reported evidence; absent on records captured by older versions. */
  mockLocationStatus?: MockLocationStatus;
}

/**
 * The options for configuring for location updates.
 *
 * @since 7.0.9
 */
export interface StartOptions {
  /**
   * If the "backgroundMessage" option is defined, the plugin will
   * provide location updates whether the app is in the background or the
   * foreground. If it is not defined, location updates are only
   * guaranteed in the foreground. This is true on both platforms.
   *
   * On Android, a notification must be shown to continue receiving
   * location updates in the background. This option specifies the text of
   * that notification.
   *
   * @since 7.0.9
   * @example "Getting your location to provide better service"
   */
  backgroundMessage?: string;
  /**
   * The title of the notification mentioned above.
   *
   * @since 7.0.9
   * @default "Using your location"
   * @example "Location Service"
   */
  backgroundTitle?: string;
  /**
   * Whether permissions should be requested from the user automatically,
   * if they are not already granted.
   *
   * @since 7.0.9
   * @default true
   */
  requestPermissions?: boolean;
  /**
   * If "true", stale locations may be delivered while the device
   * obtains a GPS fix. You are responsible for checking the "time"
   * property. If "false", locations are guaranteed to be up to date.
   *
   * @since 7.0.9
   * @default false
   */
  stale?: boolean;
  /**
   * The distance in meters that the device must move before a new location update is triggered.
   *
   * A non-zero value suppresses updates while the device is stationary (for
   * example a parked vehicle). Use {@link StartOptions.minIntervalMs} when you
   * need a lower update rate but still want periodic points without movement.
   *
   * @since 7.0.9
   * @default 0
   */
  distanceFilter?: number;
  /**
   * If false, the service will continue running after the app is terminated.
   *
   * @since 1.0.0
   * @default false
   */
  stopOnTerminate?: boolean;
  /**
   * If true, the service will restart after a device reboot if it was
   * running before the reboot.
   *
   * @since 1.0.0
   * @default true
   */
  startOnBoot?: boolean;
  /**
   * Maximum tracking duration in milliseconds. The service will auto-stop
   * after this duration to prevent indefinite battery drain if the user
   * forgets to check out.
   *
   * @since 1.0.0
   * @default 43200000 (12 hours)
   */
  maxTrackingDurationMs?: number;
  /**
   * When set, each location update is additionally delivered by POSTing it as
   * JSON to this URL directly from native code, in parallel with the
   * JavaScript callback. The request body matches the `Location` object, plus
   * an extra `"source": "native"` field so the server can tell native POSTs
   * apart from updates forwarded by the JavaScript layer.
   *
   * Native delivery does not depend on the WebView. On Android, the foreground
   * service is kept alive and restarted by the system (`START_STICKY`), so
   * location POSTs continue even after the user swipes the app away from the
   * recents list and its process is killed. On iOS, locations are POSTed
   * natively for as long as the system keeps the app running; iOS itself stops
   * location updates when the user terminates the app (an OS restriction — iOS
   * has no equivalent of Android's restartable foreground service).
   *
   * Delivery is best-effort: there is no on-disk queue and no automatic retry.
   * Failed POSTs are logged and dropped. A flaky network can delay in-flight
   * requests, but points are not persisted across process death.
   *
   * @since 8.2.0
   * @example "https://api.example.com/locations"
   */
  url?: string;
  /**
   * Extra HTTP headers for the native POST described by {@link StartOptions.url}.
   * Ignored when `url` is not set.
   *
   * On Android these headers are persisted next to `url` so a sticky service
   * restart can keep authenticating. Prefer a narrowly scoped, long-lived token
   * for this path, or call {@link BackgroundGeolocationPlugin.updateHeaders}
   * when credentials rotate. On iOS location headers stay in memory for the
   * tracking session.
   *
   * @since 8.3.3
   * @example { "Authorization": "Bearer <token>" }
   */
  headers?: Record<string, string>;
  /**
   * Minimum interval between native location POSTs, in milliseconds.
   * `0` or unset keeps the current behaviour (every provider update).
   *
   * Applied as the Android `requestLocationUpdates` interval (advisory) and as a
   * hard gate immediately before each native POST on both platforms. A point
   * older than the last one sent still passes through (late update, not a
   * faster one).
   *
   * Note: a non-zero {@link StartOptions.distanceFilter} suppresses updates while
   * the device is stationary, so it cannot substitute for a time interval when
   * you still need periodic parked-vehicle heartbeats.
   *
   * @since 8.3.3
   * @default 0
   * @example 120000
   */
  minIntervalMs?: number;
  /**
   * Android only - has no effect on iOS. Whether to fall back to
   * `NETWORK_PROVIDER` (cell/Wi-Fi based location) when `GPS_PROVIDER` has
   * not delivered a fix recently. GPS can go quiet for extended periods when
   * the app is backgrounded, the screen is locked, or the device has weak
   * sky visibility (indoors, dense urban areas); the network fallback fills
   * those gaps with a coarser, but far more reliably delivered, fix.
   *
   * GPS always takes priority: a network fix is only used once GPS has been
   * silent for 20+ seconds, and is dropped if its reported accuracy is worse
   * than 300m or unreported.
   *
   * Defaults to `false`, so existing GPS-only accuracy characteristics are
   * unchanged unless you opt in.
   *
   * @since 8.5.0
   * @default false
   * @example
   * // Fill gaps in GPS coverage with a coarser network-based location
   * networkFallback: true
   */
  networkFallback?: boolean;
}

/**
 * Represents a geographical location with various attributes.
 *
 * @since 7.0.0
 */
/** A negative OS signal is not proof that coordinates are genuine. */
export type MockLocationStatus = 'mocked' | 'not_detected' | 'unknown';

export interface Location {
  /**
   * Latitude in degrees. Range: -90.0 to +90.0
   *
   * @since 7.0.0
   */
  latitude: number;
  /**
   * Longitude in degrees. Range: -180.0 to +180.0
   *
   * @since 7.0.0
   */
  longitude: number;
  /**
   * Radius of horizontal uncertainty in metres, with 68% confidence.
   *
   * @since 7.0.0
   */
  accuracy: number;
  /**
   * Metres above sea level (or null if not available).
   *
   * @since 7.0.0
   */
  altitude: number | null;
  /**
   * Vertical uncertainty in metres, with 68% confidence (or null if not available).
   *
   * @since 7.0.0
   */
  altitudeAccuracy: number | null;
  /**
   * `true` if the location was simulated by software, rather than GPS.
   *
   * @since 7.0.0
   */
  simulated: boolean;
  /** Use this field for security decisions. Older platforms and web report unknown. */
  mockLocationStatus?: MockLocationStatus;
  /**
   * Deviation from true north in degrees (or null if not available).
   *
   * @since 7.0.0
   */
  bearing: number | null;
  /**
   * Speed in metres per second (or null if not available).
   *
   * @since 7.0.0
   */
  speed: number | null;
  /**
   * Time the location was produced, in milliseconds since the unix epoch.
   *
   * @since 7.0.0
   */
  time: number | null;
}

/**
 * Error object that may be passed to the location start callback.
 *
 * @since 7.0.0
 */
export interface CallbackError extends Error {
  /**
   * Optional error code for more specific error handling.
   *
   * @since 7.0.0
   */
  code?: string;
}

export interface SetPlannedRouteOptions {
  /**
   * The name of the sound file to play.
   * Must be a valid sound relative path in the app's public folder.
   * @since 7.0.10
   */
  soundFile: string;
  /**
   * The planned route as an array of longitude and latitude pairs.
   * @since 7.0.11
   */
  route: [number, number][];
  /**
   * The distance in meters to deviate before triggering the sound.
   * @since 7.0.11
   * @default 50
   */
  distance: number;
}

/**
 * Options for configuring native geofence transition handling.
 *
 * When `url` is provided, native code can send a JSON `POST` whenever a
 * monitored region is entered or exited. Android background POST delivery
 * requires `backgroundLocation: true`.
 *
 * @since 8.0.30
 */
export interface GeofenceSetupOptions {
  /**
   * Endpoint that receives geofence transition payloads.
   *
   * On Android, native background POST delivery requires `backgroundLocation: true`.
   *
   * Delivery is best-effort: there is no on-disk queue and no automatic retry.
   * Failed POSTs are logged and dropped.
   *
   * @since 8.0.30
   * @example "https://api.example.com/geofences"
   */
  url?: string;

  /**
   * Extra HTTP headers for the native POST described by {@link GeofenceSetupOptions.url}.
   * Ignored when `url` is not set.
   *
   * Headers are persisted with the geofence setup so transitions that fire after
   * process restart can still authenticate. Prefer a narrowly scoped token, or
   * call {@link BackgroundGeolocationPlugin.updateHeaders} when credentials rotate.
   *
   * @since 8.3.3
   * @example { "Authorization": "Bearer <token>" }
   */
  headers?: Record<string, string>;

  /**
   * Whether entry transitions should be monitored.
   *
   * @since 8.0.30
   * @default true
   * @example true
   */
  notifyOnEntry?: boolean;

  /**
   * Whether exit transitions should be monitored.
   *
   * @since 8.0.30
   * @default true
   * @example true
   */
  notifyOnExit?: boolean;

  /**
   * Base JSON payload merged into every native transition POST and listener event.
   *
   * @since 8.0.30
   * @example { "userId": "123" }
   */
  payload?: Record<string, unknown>;

  /**
   * Whether the plugin should request the native location permission needed for geofencing.
   *
   * iOS geofencing needs Always location authorization. Android geofencing requests
   * foreground location by default. Android background location is only requested when
   * `backgroundLocation` is enabled.
   *
   * @since 8.0.30
   * @default true
   * @example true
   */
  requestPermissions?: boolean;

  /**
   * Whether Android geofencing should opt into background location permission.
   *
   * The plugin does not add `ACCESS_BACKGROUND_LOCATION` to your app manifest.
   * Leave this disabled if your app does not have Google Play approval for Android
   * background location. Enable it only after adding `ACCESS_BACKGROUND_LOCATION`
   * to your app manifest and when you need Android geofence transitions while the
   * app is in the background.
   *
   * This option only affects Android. Android versions below 10 do not request
   * an extra background-location runtime permission, but the option still gates
   * native Android background geofence delivery.
   *
   * @since 8.0.34
   * @default false
   * @example false
   */
  backgroundLocation?: boolean;
}

/**
 * A circular geofence region.
 *
 * @since 8.0.30
 */
export interface AddGeofenceOptions {
  /**
   * Latitude in degrees for the region center.
   *
   * @since 8.0.30
   * @example 40.7128
   */
  latitude: number;

  /**
   * Longitude in degrees for the region center.
   *
   * @since 8.0.30
   * @example -74.006
   */
  longitude: number;

  /**
   * Region radius in meters.
   *
   * @since 8.0.30
   * @default 50
   * @example 150
   */
  radius?: number;

  /**
   * Stable identifier for the geofence.
   *
   * @since 8.0.30
   * @example "office"
   */
  identifier: string;

  /**
   * Overrides the setup-level entry setting for this region.
   *
   * @since 8.0.30
   */
  notifyOnEntry?: boolean;

  /**
   * Overrides the setup-level exit setting for this region.
   *
   * @since 8.0.30
   */
  notifyOnExit?: boolean;

  /**
   * Region-specific payload merged over the setup payload.
   *
   * @since 8.0.30
   * @example { "storeId": "nyc-1" }
   */
  payload?: Record<string, unknown>;
}

/**
 * Options for removing a monitored geofence.
 *
 * @since 8.0.30
 */
export interface RemoveGeofenceOptions {
  /**
   * Identifier passed to `addGeofence`.
   *
   * @since 8.0.30
   * @example "office"
   */
  identifier: string;
}

/**
 * Result returned when listing monitored geofences.
 *
 * @since 8.0.30
 */
export interface MonitoredGeofencesResult {
  /**
   * Identifiers for all geofences currently monitored by this plugin.
   *
   * @since 8.0.30
   * @example ["office", "warehouse"]
   */
  regions: string[];
}

/**
 * Event emitted when a monitored geofence is entered or exited.
 *
 * The same data is also sent to the configured `url`, when one is set.
 *
 * @since 8.0.30
 */
export interface GeofenceTransitionEvent {
  /**
   * Identifier of the geofence that changed state.
   *
   * @since 8.0.30
   * @example "office"
   */
  identifier: string;

  /**
   * Transition name.
   *
   * @since 8.0.30
   * @example "enter"
   */
  transition: 'enter' | 'exit';

  /**
   * `true` for entry transitions, `false` for exit transitions.
   *
   * @since 8.0.30
   * @example true
   */
  enter: boolean;

  /**
   * Latitude in degrees for the monitored region center, when available.
   *
   * @since 8.0.30
   * @example 40.7128
   */
  latitude?: number;

  /**
   * Longitude in degrees for the monitored region center, when available.
   *
   * @since 8.0.30
   * @example -74.006
   */
  longitude?: number;

  /**
   * Region radius in meters, when available.
   *
   * @since 8.0.30
   * @example 150
   */
  radius?: number;

  /**
   * Merged setup and region payload.
   *
   * @since 8.0.30
   */
  payload?: Record<string, unknown>;
}

/**
 * Event emitted when native geofence monitoring fails.
 *
 * @since 8.0.30
 */
export interface GeofenceErrorEvent {
  /**
   * Identifier of the geofence that failed, when native APIs provide it.
   *
   * @since 8.0.30
   * @example "office"
   */
  identifier?: string;

  /**
   * Native platform error code.
   *
   * @since 8.0.30
   * @example 5
   */
  code?: number;

  /**
   * Native platform error message.
   *
   * @since 8.0.30
   */
  message: string;

  /**
   * Native error domain, when available.
   *
   * @since 8.0.30
   */
  domain?: string;
}

/**
 * Options for {@link BackgroundGeolocationPlugin.updateHeaders}.
 *
 * @since 8.3.3
 */
export interface UpdateHeadersOptions {
  /**
   * Replacement HTTP headers for native POSTs configured via `url`.
   *
   * Applies to an active location watcher and to geofence setup when those
   * features have a `url`. Pass an empty object to clear custom headers.
   *
   * @since 8.3.3
   * @example { "Authorization": "Bearer <token>" }
   */
  headers: Record<string, string>;
}

/**
 * Main plugin interface for background geolocation functionality.
 *
 * @since 7.0.0
 */
export interface BackgroundGeolocationPlugin {
  /**
   * Capture one fresh foreground location with OS mock-location evidence.
   * Requires foreground location permission; never starts background tracking,
   * requests background permission, or adds this fix to the tracking buffer.
   * Rejects after 30 seconds if a fresh fix is unavailable.
   */
  getCurrentLocation(): Promise<Location>;

  /**
   * Start listening for location changes. The callback is invoked
   * each time a new location is available.
   *
   * @since 7.0.9
   */
  start(options: StartOptions, callback: (position?: Location, error?: CallbackError) => void): Promise<void>;

  /**
   * Stop location updates and the background service.
   *
   * @since 7.0.9
   */
  stop(): Promise<void>;

  /**
   * Replaces HTTP headers used by native POSTs without restarting tracking.
   *
   * Use this when an access token expires while `url` delivery is active.
   * Headers apply to the running location watcher and to geofence setup when
   * those features have a configured `url`.
   *
   * @param options The replacement headers
   * @returns A promise that resolves when headers are updated
   *
   * @since 8.3.3
   * @example
   * await BackgroundGeolocation.updateHeaders({
   *   headers: { Authorization: "Bearer <new-token>" },
   * });
   */
  updateHeaders(options: UpdateHeadersOptions): Promise<void>;

  /**
   * Opens the device's location settings page.
   *
   * @since 7.0.0
   */
  openSettings(): Promise<void>;

  /**
   * Set a planned route with audio alert on deviation.
   *
   * @since 7.0.11
   */
  setPlannedRoute(options: SetPlannedRouteOptions): Promise<void>;

  /**
   * Configures native geofence transition handling.
   *
   * Call this before adding geofences when you need default entry/exit settings
   * or native background POSTs. Android background POSTs require
   * `backgroundLocation: true`.
   *
   * @param options The geofence configuration options
   * @returns A promise that resolves once geofencing is configured
   *
   * @since 8.0.30
   * @example
   * await BackgroundGeolocation.setupGeofencing({
   *   notifyOnEntry: true,
   *   notifyOnExit: true,
   *   payload: { userId: "123" }
   * });
   */
  setupGeofencing(options: GeofenceSetupOptions): Promise<void>;

  /**
   * Starts monitoring a circular native geofence.
   *
   * @param options The geofence region options
   * @returns A promise that resolves when native monitoring starts
   *
   * @since 8.0.30
   * @example
   * await BackgroundGeolocation.addGeofence({
   *   identifier: "office",
   *   latitude: 40.7128,
   *   longitude: -74.006,
   *   radius: 150
   * });
   */
  addGeofence(options: AddGeofenceOptions): Promise<void>;

  /**
   * Stops monitoring one geofence.
   *
   * @param options The geofence identifier
   * @returns A promise that resolves when native monitoring stops
   *
   * @since 8.0.30
   * @example
   * await BackgroundGeolocation.removeGeofence({ identifier: "office" });
   */
  removeGeofence(options: RemoveGeofenceOptions): Promise<void>;

  /**
   * Stops monitoring every geofence registered by this plugin.
   *
   * @returns A promise that resolves when all native geofences are removed
   *
   * @since 8.0.30
   * @example
   * await BackgroundGeolocation.removeAllGeofences();
   */
  removeAllGeofences(): Promise<void>;

  /**
   * Lists the geofence identifiers currently monitored by this plugin.
   *
   * @returns A promise with monitored geofence identifiers
   *
   * @since 8.0.30
   * @example
   * const { regions } = await BackgroundGeolocation.getMonitoredGeofences();
   */
  getMonitoredGeofences(): Promise<MonitoredGeofencesResult>;

  /**
   * Listens for geofence enter/exit transitions while the WebView is alive.
   *
   * Native `url` delivery configured through `setupGeofencing` is used for
   * background-safe delivery.
   *
   * @since 8.0.30
   * @example
   * const handle = await BackgroundGeolocation.addListener(
   *   "geofenceTransition",
   *   (event) => console.log(event.identifier, event.transition)
   * );
   */
  addListener(
    eventName: 'geofenceTransition',
    listenerFunc: (event: GeofenceTransitionEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Listens for native geofence monitoring errors while the WebView is alive.
   *
   * @since 8.0.30
   * @example
   * const handle = await BackgroundGeolocation.addListener(
   *   "geofenceError",
   *   (event) => console.error(event.identifier, event.message)
   * );
   */
  addListener(
    eventName: 'geofenceError',
    listenerFunc: (event: GeofenceErrorEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Read current location authorization without prompting or side effects.
   *
   * On iOS this maps `CLAuthorizationStatus` so you can distinguish Always from
   * While Using App. On Android this reports foreground location,
   * `ACCESS_BACKGROUND_LOCATION`, and notification permission where relevant.
   *
   * @returns Current permission status for this plugin
   *
   * @since 8.0.43
   * @example
   * const status = await BackgroundGeolocation.checkPermissions();
   * if (status.backgroundLocation === 'when_in_use') {
   *   // Show UI explaining why Always access is needed
   * }
   */
  checkPermissions(): Promise<BackgroundGeolocationPermissionStatus>;

  /**
   * Request location-related permissions from the user.
   *
   * Prefer {@link BackgroundGeolocationPlugin.checkPermissions} for read-only
   * status in settings screens. Call this only when the user has opted in.
   *
   * @param options Optional subset of permissions to request
   * @returns Permission status after the request flow completes
   *
   * @since 8.0.43
   * @example
   * const status = await BackgroundGeolocation.requestPermissions({
   *   permissions: ['backgroundLocation'],
   * });
   */
  requestPermissions(
    options?: RequestBackgroundGeolocationPermissionsOptions,
  ): Promise<BackgroundGeolocationPermissionStatus>;

  /**
   * Get the native Capacitor plugin version
   *
   * @returns {Promise<{ id: string }>} an Promise with version for this device
   * @throws An error if the something went wrong
   */
  getPluginVersion(): Promise<{ version: string }>;

  /**
   * Configure headless mode for native HTTP posting of location
   * batches to a server endpoint. Call this before start() or
   * whenever the auth token needs refreshing.
   *
   * @since 1.0.0
   */
  configure(config: HeadlessConfig): Promise<void>;

  /**
   * Get all locations buffered locally on the device.
   *
   * @since 1.0.0
   */
  getBufferedLocations(): Promise<{ locations: BufferedLocation[] }>;

  /**
   * Clear all locally buffered locations.
   *
   * @since 1.0.0
   */
  clearBufferedLocations(): Promise<void>;

  /**
   * Get the current native location authorization status.
   *
   * - `notDetermined` — user has never been asked (iOS) or permission hasn't been requested (Android)
   * - `whenInUse` — user allowed location only while using the app (iOS) / foreground only (Android)
   * - `always` — user allowed location all the time (iOS) / background granted (Android)
   * - `denied` — user denied location access
   * - `restricted` — location is restricted by parental controls or MDM (iOS only)
   *
   * Use this to detect whether to show an in-app prompt asking the user to upgrade
   * from "While Using" to "Always" via Settings.
   *
   * @since 1.0.0
   */
  getAuthorizationStatus(): Promise<{ status: 'notDetermined' | 'whenInUse' | 'always' | 'denied' | 'restricted' }>;
}
