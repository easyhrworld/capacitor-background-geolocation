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
}

/**
 * Represents a geographical location with various attributes.
 *
 * @since 7.0.0
 */
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
 * Main plugin interface for background geolocation functionality.
 *
 * @since 7.0.0
 */
export interface BackgroundGeolocationPlugin {
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
   * Get the native Capacitor plugin version.
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
}
