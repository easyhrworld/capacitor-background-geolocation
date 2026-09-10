package com.easyhrworld.capacitor_background_geolocation;

import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.content.res.AssetFileDescriptor;
import android.content.res.AssetManager;
import android.graphics.Color;
import android.location.LocationListener;
import android.location.LocationManager;
import android.media.MediaPlayer;
import android.os.Binder;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import androidx.core.app.NotificationCompat;
import androidx.core.app.ServiceCompat;
import androidx.core.location.LocationListenerCompat;
import com.getcapacitor.Logger;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONObject;

// A bound and started service that is promoted to a foreground service
// (showing a persistent notification) when the first background watcher is
// added, and demoted when the last background watcher is removed.
public class BackgroundGeolocationService extends Service {

    static final String NOTIFICATION_CHANNEL_ID = BackgroundGeolocationService.class.getPackage().getName();
    private final IBinder binder = new LocalBinder();

    private static final double EARTH_RADIUS_M = 6371000;

    // Must be unique for this application.
    private static final int NOTIFICATION_ID = 28351;

    private static final String PREFS_NAME = "bg_geo_prefs";
    // Preserve EasyHR's attendance-session limit across UI/process restarts.
    private static final long MAX_TRACKING_DURATION_MS = 12 * 60 * 60 * 1000L;
    private LocationBuffer locationBuffer;
    private HeadlessHttpPoster httpPoster;
    private Handler postHandler;
    private Runnable postRunnable;
    private Handler autoStopHandler;
    private Runnable autoStopRunnable;
    private ExecutorService headlessExecutor;

    @Override
    public void onCreate() {
        super.onCreate();
        locationBuffer = new LocationBuffer(this);
        httpPoster = new HeadlessHttpPoster(this);
        headlessExecutor = Executors.newSingleThreadExecutor();
    }

    private boolean isTrackingPersisted() {
        return getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getBoolean("is_tracking", false);
    }

    private String callbackId;

    private LocationManager client;
    private LocationListener locationCallback;
    private MediaPlayer mediaPlayer;
    private double[][] route;
    private double distanceThreshold;
    private boolean isOffRoute;

    private Handler watchdogHandler = new Handler(Looper.getMainLooper());
    private Runnable watchdogRunnable;
    private Runnable restartRunnable;
    private float currentDistanceFilter;
    private long currentMinIntervalMs;
    private PowerManager.WakeLock wakeLock;

    // How long a GPS fix is considered "fresh" before we allow a NETWORK_PROVIDER fix through.
    private static final long NETWORK_FALLBACK_GRACE_MS = 20000L;

    // Max acceptable accuracy radius (meters) for a NETWORK_PROVIDER fix; missing accuracy counts
    // as too imprecise too.
    private static final float NETWORK_FIX_MAX_ACCURACY_M = 300f;

    // elapsedRealtime() of the last GPS_PROVIDER fix, or 0 if none yet. Monotonic, so it can't be
    // confused by wall-clock adjustments the way System.currentTimeMillis() could.
    private volatile long lastGpsFixAtMs = 0L;

    // Opt-in flag for the NETWORK_PROVIDER fallback below; set via the "networkFallback" start
    // option. Defaults to off, so GPS-only accuracy is unchanged unless a caller asks for it.
    private volatile boolean networkFallbackEnabled = false;

    // When set (via the "url" start option), each location is also POSTed to
    // this URL directly from native code so delivery survives the WebView being
    // destroyed. Delivery runs on postExecutor to keep it off the main thread.
    private String nativePostUrl;
    private ExecutorService postExecutor;

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    // EasyHR's durable batch uploader and upstream native delivery both outlive the UI.
    @Override
    public boolean onUnbind(Intent intent) {
        releaseMediaPlayer();
        if (!isTrackingPersisted()) {
            ((LocalBinder) binder).stop();
        }
        return true;
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        if (!isTrackingPersisted()) {
            super.onTaskRemoved(rootIntent);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        if (!isTrackingPersisted()) {
            // The initial start command arrives before LocalBinder.start persists the session.
            return START_STICKY;
        }
        long startedAt = prefs.getLong("tracking_start_time", 0);
        if (System.currentTimeMillis() - startedAt >= MAX_TRACKING_DURATION_MS) {
            ((LocalBinder) binder).stop();
            return START_NOT_STICKY;
        }
        if (client == null || locationCallback == null) {
            nativePostUrl = LocationStore.getUrl(this);
            promoteToForeground(prefs.getString("notification_title", "Using your location"), prefs.getString("notification_message", ""));
            acquireWakeLock();
            client = (LocationManager) getSystemService(Context.LOCATION_SERVICE);
            currentDistanceFilter = prefs.getFloat("distance_filter", 0f);
            currentMinIntervalMs = prefs.getLong("min_interval_ms", 10000L);
            networkFallbackEnabled = prefs.getBoolean("network_fallback", false);
            locationCallback = createLocationListener(this);
            lastGpsFixAtMs = SystemClock.elapsedRealtime();
            requestLocationUpdates();
            startWatchdog();
            startHeadlessPosting();
            scheduleAutoStop(startedAt);
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (client != null && locationCallback != null) {
            client.removeUpdates(locationCallback);
        }
        stopHeadlessPosting();
        cancelAutoStop();
        // Queue close after any pending batch has finished reading/deleting rows.
        headlessExecutor.execute(() -> locationBuffer.close());
        headlessExecutor.shutdown();
        super.onDestroy();
        releaseMediaPlayer();
        releaseWakeLock();
        stopWatchdog();
        if (postExecutor != null) {
            postExecutor.shutdown();
            postExecutor = null;
        }
    }

    private void releaseMediaPlayer() {
        if (mediaPlayer == null) {
            return;
        }
        try {
            if (mediaPlayer.isPlaying()) {
                mediaPlayer.stop();
            }
            mediaPlayer.release();
        } catch (Exception e) {
            Logger.error("Error releasing MediaPlayer", e);
        }
        mediaPlayer = null;
    }

    // No timeout: tracking runs for as long as the caller keeps a background watcher
    // registered, and the lock is always released in stop() and onDestroy().
    @SuppressLint("WakelockTimeout")
    private void acquireWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) {
            return;
        }
        try {
            PowerManager powerManager = (PowerManager) getSystemService(Context.POWER_SERVICE);
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "BackgroundGeolocation::LocationWakeLock");
            wakeLock.acquire();
            Logger.info("Wake lock acquired");
        } catch (Exception e) {
            Logger.error("Error acquiring wake lock", e);
        }
    }

    private void releaseWakeLock() {
        if (wakeLock == null) {
            return;
        }
        try {
            if (wakeLock.isHeld()) {
                wakeLock.release();
                Logger.info("Wake lock released");
            }
        } catch (Exception e) {
            Logger.error("Error releasing wake lock", e);
        }
        wakeLock = null;
    }

    private void saveTrackingState(String notificationTitle, String notificationMessage, float distanceFilter) {
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        prefs
            .edit()
            .putBoolean("is_tracking", true)
            .putLong("tracking_start_time", System.currentTimeMillis())
            .putFloat("distance_filter", distanceFilter)
            .putString("notification_title", notificationTitle)
            .putString("notification_message", notificationMessage)
            .apply();
    }

    private void clearTrackingState() {
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        prefs.edit().putBoolean("is_tracking", false).remove("tracking_start_time").apply();
    }

    private void startHeadlessPosting() {
        if (postHandler != null) return;
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        int postIntervalMs = prefs.getInt("headless_post_interval", 60000);

        postHandler = new Handler(Looper.getMainLooper());
        postRunnable = new Runnable() {
            @Override
            public void run() {
                headlessExecutor.execute(() -> {
                    try {
                        httpPoster.postBatch(locationBuffer);
                    } catch (Exception e) {
                        Logger.error("Headless HTTP post failed", e);
                    }
                });
                postHandler.postDelayed(this, postIntervalMs);
            }
        };
        postHandler.postDelayed(postRunnable, postIntervalMs);
    }

    private void stopHeadlessPosting() {
        if (postHandler != null && postRunnable != null) {
            postHandler.removeCallbacks(postRunnable);
        }
        postHandler = null;
        postRunnable = null;
    }

    private void scheduleAutoStop(long trackingStartTime) {
        cancelAutoStop();
        long remaining = MAX_TRACKING_DURATION_MS - (System.currentTimeMillis() - trackingStartTime);
        autoStopHandler = new Handler(Looper.getMainLooper());
        autoStopRunnable = () -> ((LocalBinder) binder).stop();
        autoStopHandler.postDelayed(autoStopRunnable, Math.max(0L, remaining));
    }

    private void cancelAutoStop() {
        if (autoStopHandler != null && autoStopRunnable != null) {
            autoStopHandler.removeCallbacks(autoStopRunnable);
        }
        autoStopHandler = null;
        autoStopRunnable = null;
    }

    private void restartLocationUpdates() {
        Logger.debug("Location watchdog timed out, restarting updates");
        if (client == null || locationCallback == null) {
            return;
        }
        client.removeUpdates(locationCallback);
        if (restartRunnable != null) {
            watchdogHandler.removeCallbacks(restartRunnable);
        }
        restartRunnable = () -> {
            if (client == null || locationCallback == null) {
                return;
            }
            requestLocationUpdates();
            startWatchdog();
        };
        watchdogHandler.postDelayed(restartRunnable, 10000);
    }

    private void startWatchdog() {
        stopWatchdog();
        if (watchdogRunnable == null) {
            watchdogRunnable = this::restartLocationUpdates;
        }
        watchdogHandler.postDelayed(watchdogRunnable, 60000);
    }

    private void stopWatchdog() {
        if (watchdogRunnable != null) {
            watchdogHandler.removeCallbacks(watchdogRunnable);
        }
        if (restartRunnable != null) {
            watchdogHandler.removeCallbacks(restartRunnable);
        }
    }

    private void handleLocationChanged(android.location.Location location) {
        if (LocationManager.GPS_PROVIDER.equals(location.getProvider())) {
            lastGpsFixAtMs = SystemClock.elapsedRealtime();
        } else if (LocationManager.NETWORK_PROVIDER.equals(location.getProvider())) {
            boolean gpsStillFresh = lastGpsFixAtMs != 0 && (SystemClock.elapsedRealtime() - lastGpsFixAtMs) < NETWORK_FALLBACK_GRACE_MS;
            boolean tooImprecise = !location.hasAccuracy() || location.getAccuracy() > NETWORK_FIX_MAX_ACCURACY_M;
            if (gpsStillFresh || tooImprecise) {
                // Drop it - and skip startWatchdog() below so a run of rejected fixes can't mask a
                // genuinely stalled GPS_PROVIDER and suppress the restart that would recover it.
                return;
            }
        }
        startWatchdog();
        locationBuffer.insert(location);
        if (nativePostUrl != null) {
            postLocationNatively(location);
        }
        if (mediaPlayer != null && route != null) {
            double[] point = { location.getLongitude(), location.getLatitude() };
            var offRoute = distancePointToRoute(point) > distanceThreshold;
            if (offRoute == true && isOffRoute == false) {
                mediaPlayer.start();
            }
            isOffRoute = offRoute;
        }
        LocalEvents.emitLocation(callbackId, location);
    }

    // Delivers a location to the configured URL from native code, so it works
    // even when the WebView/JavaScript layer no longer exists.
    private void postLocationNatively(android.location.Location location) {
        if (postExecutor == null) {
            postExecutor = Executors.newSingleThreadExecutor();
        }
        Context context = getApplicationContext();
        JSONObject payload = locationToJson(location);
        postExecutor.execute(() -> {
            try {
                LocationStore.sendLocation(context, payload);
            } catch (Exception e) {
                Logger.error("Native location POST failed", e);
            }
        });
    }

    private static JSONObject locationToJson(android.location.Location location) {
        JSONObject obj = new JSONObject();
        try {
            obj.put("latitude", location.getLatitude());
            obj.put("longitude", location.getLongitude());
            obj.put("accuracy", location.hasAccuracy() ? location.getAccuracy() : JSONObject.NULL);
            obj.put("altitude", location.hasAltitude() ? location.getAltitude() : JSONObject.NULL);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && location.hasVerticalAccuracy()) {
                obj.put("altitudeAccuracy", location.getVerticalAccuracyMeters());
            } else {
                obj.put("altitudeAccuracy", JSONObject.NULL);
            }
            obj.put("simulated", LocationEvidence.isMocked(location));
            obj.put("mockLocationStatus", LocationEvidence.status(location));
            obj.put("speed", location.hasSpeed() ? location.getSpeed() : JSONObject.NULL);
            obj.put("bearing", location.hasBearing() ? location.getBearing() : JSONObject.NULL);
            obj.put("time", location.getTime());
            // Lets the server distinguish native-delivered updates from those
            // forwarded by the JavaScript callback.
            obj.put("source", "native");
        } catch (org.json.JSONException e) {
            Logger.error("Could not serialize location", e);
        }
        return obj;
    }

    // Android API < 30
    static LocationListenerCompat createLocationListener(final BackgroundGeolocationService service) {
        return (location) -> service.handleLocationChanged(location);
    }

    private long locationIntervalMs() {
        return currentMinIntervalMs > 0 ? currentMinIntervalMs : 1000L;
    }

    private void requestLocationUpdates() {
        try {
            client.requestLocationUpdates(LocationManager.GPS_PROVIDER, locationIntervalMs(), currentDistanceFilter, locationCallback);
        } catch (SecurityException ignore) {
            // According to Android Studio, this method can throw a Security Exception if
            // permissions are not yet granted. Rather than check the permissions, which is fiddly,
            // we simply ignore the exception.
        }
        if (!networkFallbackEnabled) {
            return;
        }
        // GPS_PROVIDER can go quiet for extended periods in the background or with poor sky
        // visibility. Request NETWORK_PROVIDER on the same listener as a fallback; whichever
        // fires first reaches handleLocationChanged(). No manifest change needed -
        // ACCESS_COARSE_LOCATION is already declared. isProviderEnabled guards against devices
        // with network location turned off.
        try {
            if (client.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                client.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    locationIntervalMs(),
                    currentDistanceFilter,
                    locationCallback
                );
            }
        } catch (SecurityException ignore) {
            // Same rationale as the GPS_PROVIDER catch above.
        }
    }

    // Promote the service to the foreground if necessary.
    // Ideally we would only call 'startForeground' if the service is not already
    // foregrounded. Unfortunately, 'getForegroundServiceType' was only introduced
    // in API level 29 and seems to behave weirdly, as reported in #120. However,
    // it appears that 'startForeground' is idempotent, so we just call it repeatedly
    // each time a background watcher is added.
    private void promoteToForeground(String notificationTitle, String notificationMessage) {
        try {
            // This method has been known to fail due to weird
            // permission bugs, so we prevent any exceptions from
            // crashing the app.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    createBackgroundNotification(notificationTitle, notificationMessage),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                );
            } else {
                startForeground(NOTIFICATION_ID, createBackgroundNotification(notificationTitle, notificationMessage));
            }
        } catch (Exception exception) {
            Logger.error("Failed to foreground service", exception);
        }
    }

    // Handles requests from the activity.
    public class LocalBinder extends Binder {

        void start(
            final String id,
            final String notificationTitle,
            final String notificationMessage,
            float distanceFilter,
            final String url,
            final Map<String, String> headers,
            final long minIntervalMs,
            final boolean networkFallback
        ) {
            releaseMediaPlayer();
            saveTrackingState(notificationTitle, notificationMessage, distanceFilter);
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .edit()
                .putLong("min_interval_ms", Math.max(0L, minIntervalMs))
                .putBoolean("network_fallback", networkFallback)
                .apply();
            startHeadlessPosting();
            scheduleAutoStop(System.currentTimeMillis());
            acquireWakeLock();
            client = (LocationManager) getSystemService(Context.LOCATION_SERVICE);
            lastGpsFixAtMs = SystemClock.elapsedRealtime();
            callbackId = id;
            currentDistanceFilter = distanceFilter;
            currentMinIntervalMs = Math.max(0L, minIntervalMs);
            networkFallbackEnabled = networkFallback;

            nativePostUrl = (url == null || url.isEmpty()) ? null : url;
            LocationStore.saveSetup(
                getApplicationContext(),
                nativePostUrl,
                notificationTitle,
                notificationMessage,
                distanceFilter,
                headers,
                currentMinIntervalMs,
                networkFallback
            );

            // The service may already be running (for example after a sticky
            // restart), so drop any previous listener before registering a new one.
            if (locationCallback != null) {
                client.removeUpdates(locationCallback);
            }
            locationCallback = createLocationListener(BackgroundGeolocationService.this);
            requestLocationUpdates();
            // Arm the watchdog here so rejected network fixes during the grace period cannot
            // leave tracking without a restart path if GPS_PROVIDER goes silent.
            startWatchdog();
            promoteToForeground(notificationTitle, notificationMessage);
        }

        void updateHeaders(final Map<String, String> headers) {
            LocationStore.saveHeaders(getApplicationContext(), headers);
        }

        String stop() {
            clearTrackingState();
            stopHeadlessPosting();
            cancelAutoStop();
            LocationStore.clear(getApplicationContext());
            nativePostUrl = null;
            stopWatchdog();
            if (client != null && locationCallback != null) {
                client.removeUpdates(locationCallback);
            }
            locationCallback = null;
            ServiceCompat.stopForeground(BackgroundGeolocationService.this, ServiceCompat.STOP_FOREGROUND_REMOVE);
            stopSelf();
            releaseMediaPlayer();
            releaseWakeLock();
            String stoppedCallbackId = callbackId;
            callbackId = null;
            return stoppedCallbackId;
        }

        void setPlannedRoute(String filePath, double[][] routeCoordinates, float distance) {
            route = routeCoordinates;
            distanceThreshold = distance;
            isOffRoute = true;
            try {
                if (mediaPlayer != null) {
                    return;
                }
                mediaPlayer = new MediaPlayer();
                AssetManager am = getApplicationContext().getResources().getAssets();
                AssetFileDescriptor assetFileDescriptor = am.openFd("public/" + filePath);

                mediaPlayer.setDataSource(
                    assetFileDescriptor.getFileDescriptor(),
                    assetFileDescriptor.getStartOffset(),
                    assetFileDescriptor.getLength()
                );
                mediaPlayer.setLooping(false);

                mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                    Logger.error("MediaPlayer error: what=" + what + ", extra=" + extra);
                    releaseMediaPlayer();
                    return true; // Indicate we handled the error
                });

                mediaPlayer.prepareAsync();
            } catch (Exception e) {
                Logger.error("PlaySound: Unexpected error", e);
                releaseMediaPlayer();
            }
        }
    }

    private Notification createBackgroundNotification(String backgroundTitle, String backgroundMessage) {
        NotificationCompat.Builder builder = new NotificationCompat.Builder(getApplicationContext(), NOTIFICATION_CHANNEL_ID)
            .setContentTitle(backgroundTitle)
            .setContentText(backgroundMessage)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setWhen(System.currentTimeMillis());

        try {
            String name = getAppString("capacitor_background_geolocation_notification_icon", null, getApplicationContext());
            if (name != null) {
                String[] parts = name.split("/");
                int iconId = getAppResourceIdentifier(parts[1], parts[0], getApplicationContext());
                if (iconId != 0) {
                    builder.setSmallIcon(iconId);
                } else {
                    builder.setSmallIcon(android.R.drawable.ic_menu_mylocation);
                }
            } else {
                // Use Android's built-in location icon as default (proper monochrome)
                builder.setSmallIcon(android.R.drawable.ic_menu_mylocation);
            }
        } catch (Exception e) {
            Logger.error("Could not set notification icon", e);
            builder.setSmallIcon(android.R.drawable.ic_menu_mylocation);
        }

        try {
            String color = getAppString("capacitor_background_geolocation_notification_color", null, getApplicationContext());
            if (color != null) {
                builder.setColor(Color.parseColor(color));
            }
        } catch (Exception e) {
            Logger.error("Could not set notification color", e);
        }

        Intent launchIntent = getApplicationContext()
            .getPackageManager()
            .getLaunchIntentForPackage(getApplicationContext().getPackageName());
        if (launchIntent != null) {
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
            builder.setContentIntent(
                PendingIntent.getActivity(
                    getApplicationContext(),
                    0,
                    launchIntent,
                    PendingIntent.FLAG_CANCEL_CURRENT | PendingIntent.FLAG_IMMUTABLE
                )
            );
        }

        return builder.build();
    }

    // Gets the identifier of the app's resource by name, returning 0 if not found.
    // The name comes from the host app's configuration, so it can only be resolved by
    // reflection; the compile-time R class of this library does not contain it.
    @SuppressLint("DiscouragedApi")
    private static int getAppResourceIdentifier(String name, String defType, Context context) {
        return context.getResources().getIdentifier(name, defType, context.getPackageName());
    }

    // Gets a string from the app's strings.xml file, resorting to a fallback if it is not defined.
    public static String getAppString(String name, String fallback, Context context) {
        int id = getAppResourceIdentifier(name, "string", context);
        return id == 0 ? fallback : context.getString(id);
    }

    private static double haversine(double[] point1, double[] point2) {
        double lon1 = point1[0];
        double lat1 = point1[1];
        double lon2 = point2[0];
        double lat2 = point2[1];

        double dLat = Math.toRadians(lat2 - lat1);
        double dLon = Math.toRadians(lon2 - lon1);

        double a =
            Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) * Math.sin(dLon / 2) * Math.sin(dLon / 2);

        double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

        return EARTH_RADIUS_M * c;
    }

    private static double distancePointToLineSegment(double[] point, double[] lineStart, double[] lineEnd) {
        // Calculate the distances between the three points using Haversine
        double dist_A_B = haversine(point, lineStart);
        double dist_A_C = haversine(point, lineEnd);
        double dist_B_C = haversine(lineStart, lineEnd);

        // Handle the edge case where the line segment is a single point
        if (dist_B_C == 0) {
            return dist_A_B;
        }

        // Check if the angles at the line segment's endpoints are obtuse.
        // We use the Law of Cosines (c^2 = a^2 + b^2 - 2ab*cos(C))
        // If cos(C) < 0, the angle is obtuse.

        // Angle at B (lineStart)
        // Use a small epsilon to handle floating point inaccuracies in division by zero
        double cos_B = (Math.pow(dist_A_B, 2) + Math.pow(dist_B_C, 2) - Math.pow(dist_A_C, 2)) / (2 * dist_A_B * dist_B_C);
        if (cos_B < 0) {
            return dist_A_B;
        }

        // Angle at C (lineEnd)
        double cos_C = (Math.pow(dist_A_C, 2) + Math.pow(dist_B_C, 2) - Math.pow(dist_A_B, 2)) / (2 * dist_A_C * dist_B_C);
        if (cos_C < 0) {
            return dist_A_C;
        }

        // If both angles are acute, the closest point is on the line segment itself.
        // We can calculate the distance (height of the triangle) using its area.

        // 1. Calculate the semi-perimeter of the triangle ABC
        double s = (dist_A_B + dist_A_C + dist_B_C) / 2;

        // 2. Calculate the area using Heron's formula
        double area = Math.sqrt(Math.max(0, s * (s - dist_A_B) * (s - dist_A_C) * (s - dist_B_C)));

        // 3. The distance is the height of the triangle from point A to the base BC
        // Area = 0.5 * base * height  =>  height = 2 * Area / base
        return (2 * area) / dist_B_C;
    }

    public double distancePointToRoute(double[] point) {
        // If the polyline has less than 2 points, we can't form a segment.
        if (this.route.length < 2) {
            if (this.route.length == 1) {
                return haversine(point, this.route[0]);
            }
            return Double.POSITIVE_INFINITY; // No line segments to measure against
        }

        double minDistance = Double.POSITIVE_INFINITY;

        for (int i = 0; i < this.route.length - 1; i++) {
            double[] lineStart = this.route[i];
            double[] lineEnd = this.route[i + 1];
            double distance = distancePointToLineSegment(point, lineStart, lineEnd);
            if (distance < minDistance) {
                minDistance = distance;
            }
        }

        return minDistance;
    }
}
