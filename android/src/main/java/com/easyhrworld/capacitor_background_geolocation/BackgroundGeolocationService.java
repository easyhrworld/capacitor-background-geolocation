package com.easyhrworld.capacitor_background_geolocation;

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
import android.location.Location;
import android.media.MediaPlayer;
import android.os.Binder;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import androidx.localbroadcastmanager.content.LocalBroadcastManager;
import com.getcapacitor.Logger;
import com.google.android.gms.location.FusedLocationProviderClient;
import com.google.android.gms.location.LocationCallback;
import com.google.android.gms.location.LocationRequest;
import com.google.android.gms.location.LocationResult;
import com.google.android.gms.location.LocationServices;
import com.google.android.gms.location.Priority;

// A bound and started service that is promoted to a foreground service
// (showing a persistent notification) when the first background watcher is
// added, and demoted when the last background watcher is removed.
public class BackgroundGeolocationService extends Service {

    static final String ACTION_BROADCAST = (BackgroundGeolocationService.class.getPackage().getName() + ".broadcast");
    private final IBinder binder = new LocalBinder();

    private static final double EARTH_RADIUS_M = 6371000;
    private static final int NOTIFICATION_ID = 28351;
    private static final String PREFS_NAME = "bg_geo_prefs";
    private static final long MAX_TRACKING_DURATION_MS = 12 * 60 * 60 * 1000L; // 12 hours

    private String callbackId;

    private FusedLocationProviderClient fusedLocationClient;
    private LocationCallback fusedLocationCallback;
    private MediaPlayer mediaPlayer;
    private double[][] route;
    private double distanceThreshold;
    private boolean isOffRoute;

    private float currentDistanceFilter;
    private PowerManager.WakeLock wakeLock;

    // Headless mode
    private LocationBuffer locationBuffer;
    private HeadlessHttpPoster httpPoster;
    private Handler postHandler;
    private Runnable postRunnable;
    private Handler autoStopHandler;
    private Runnable autoStopRunnable;

    @Override
    public void onCreate() {
        super.onCreate();
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this);
        locationBuffer = new LocationBuffer(this);
        httpPoster = new HeadlessHttpPoster(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        boolean wasTracking = prefs.getBoolean("is_tracking", false);

        if (wasTracking && fusedLocationCallback == null) {
            // Service restarted by OS (START_STICKY) or boot receiver
            long trackingStartTime = prefs.getLong("tracking_start_time", 0);
            long elapsed = System.currentTimeMillis() - trackingStartTime;

            if (elapsed < MAX_TRACKING_DURATION_MS) {
                Logger.info("Restoring background tracking after restart");
                restoreAndStartTracking();
            } else {
                Logger.info("Tracking exceeded 12-hour limit, stopping service");
                clearTrackingState();
                stopSelf();
            }
        }

        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    // When the app unbinds (e.g. app killed), the service continues running
    // in the background as a foreground service. Returning true enables
    // onRebind() when the app reconnects.
    @Override
    public boolean onUnbind(Intent intent) {
        // Do NOT stop location updates or call stopSelf() — the service
        // must survive app termination to continue tracking.
        releaseMediaPlayer();
        return true; // triggers onRebind() when app reconnects
    }

    @Override
    public void onRebind(Intent intent) {
        super.onRebind(intent);
        Logger.info("App reconnected to background geolocation service");
    }

    @Override
    public void onDestroy() {
        stopFusedLocationUpdates();
        stopHeadlessPosting();
        cancelAutoStop();
        releaseMediaPlayer();
        releaseWakeLock();
        if (locationBuffer != null) {
            locationBuffer.close();
        }
        super.onDestroy();
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
        prefs.edit()
            .putBoolean("is_tracking", true)
            .putLong("tracking_start_time", System.currentTimeMillis())
            .putFloat("distance_filter", distanceFilter)
            .putString("notification_title", notificationTitle)
            .putString("notification_message", notificationMessage)
            .apply();
    }

    private void clearTrackingState() {
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        prefs.edit()
            .putBoolean("is_tracking", false)
            .remove("tracking_start_time")
            .apply();
    }

    private void restoreAndStartTracking() {
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        float distanceFilter = prefs.getFloat("distance_filter", 0f);
        String notificationTitle = prefs.getString("notification_title", "Using your location");
        String notificationMessage = prefs.getString("notification_message", "");

        acquireWakeLock();
        currentDistanceFilter = distanceFilter;

        startFusedLocationUpdates(distanceFilter);
        startHeadlessPosting();
        scheduleAutoStop(prefs.getLong("tracking_start_time", System.currentTimeMillis()));

        try {
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
            Logger.error("Failed to foreground service on restore", exception);
        }
    }

    private void startFusedLocationUpdates(float distanceFilter) {
        LocationRequest locationRequest = new LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY, 10000
        )
            .setMinUpdateDistanceMeters(distanceFilter)
            .setWaitForAccurateLocation(false)
            .build();

        fusedLocationCallback = new LocationCallback() {
            @Override
            public void onLocationResult(LocationResult result) {
                Location location = result.getLastLocation();
                if (location == null) return;

                // Buffer location for headless sync
                if (locationBuffer != null) {
                    locationBuffer.insert(location);
                }

                // Route deviation check
                if (mediaPlayer != null && route != null) {
                    double[] point = { location.getLongitude(), location.getLatitude() };
                    boolean offRoute = distancePointToRoute(point) > distanceThreshold;
                    if (offRoute && !isOffRoute) {
                        mediaPlayer.start();
                    }
                    isOffRoute = offRoute;
                }

                // Broadcast to plugin (if app is alive)
                Intent intent = new Intent(ACTION_BROADCAST);
                intent.putExtra("location", location);
                intent.putExtra("id", callbackId);
                LocalBroadcastManager.getInstance(getApplicationContext()).sendBroadcast(intent);
            }
        };

        try {
            fusedLocationClient.requestLocationUpdates(
                locationRequest, fusedLocationCallback, Looper.getMainLooper()
            );
        } catch (SecurityException e) {
            Logger.error("Location permission not granted", e);
        }
    }

    private void stopFusedLocationUpdates() {
        if (fusedLocationClient != null && fusedLocationCallback != null) {
            fusedLocationClient.removeLocationUpdates(fusedLocationCallback);
            fusedLocationCallback = null;
        }
    }

    private void startHeadlessPosting() {
        if (postHandler != null) return;
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        int postIntervalMs = prefs.getInt("headless_post_interval", 60000);

        postHandler = new Handler(Looper.getMainLooper());
        postRunnable = new Runnable() {
            @Override
            public void run() {
                new Thread(() -> {
                    try {
                        httpPoster.postBatch(locationBuffer);
                    } catch (Exception e) {
                        Logger.error("Headless HTTP post failed", e);
                    }
                }).start();
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
        long remaining = MAX_TRACKING_DURATION_MS - (System.currentTimeMillis() - trackingStartTime);
        if (remaining <= 0) {
            Logger.info("Tracking duration exceeded, stopping immediately");
            clearTrackingState();
            stopFusedLocationUpdates();
            stopHeadlessPosting();
            releaseWakeLock();
            stopForeground(true);
            stopSelf();
            return;
        }

        autoStopHandler = new Handler(Looper.getMainLooper());
        autoStopRunnable = () -> {
            Logger.info("12-hour auto-stop triggered");
            clearTrackingState();
            stopFusedLocationUpdates();
            stopHeadlessPosting();
            releaseWakeLock();
            stopForeground(true);
            stopSelf();
        };
        autoStopHandler.postDelayed(autoStopRunnable, remaining);
    }

    private void cancelAutoStop() {
        if (autoStopHandler != null && autoStopRunnable != null) {
            autoStopHandler.removeCallbacks(autoStopRunnable);
        }
        autoStopHandler = null;
        autoStopRunnable = null;
    }

    // Handles requests from the activity.
    public class LocalBinder extends Binder {

        void start(final String id, final String notificationTitle, final String notificationMessage, float distanceFilter) {
            releaseMediaPlayer();
            acquireWakeLock();
            callbackId = id;
            currentDistanceFilter = distanceFilter;

            // Save tracking state for recovery after OS kill or reboot
            saveTrackingState(notificationTitle, notificationMessage, distanceFilter);

            // Use FusedLocationProviderClient for better accuracy and battery
            startFusedLocationUpdates(distanceFilter);

            // Start headless HTTP posting
            startHeadlessPosting();

            // Schedule 12-hour auto-stop
            scheduleAutoStop(System.currentTimeMillis());

            // Promote to foreground service
            try {
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

        String stop() {
            clearTrackingState();
            stopFusedLocationUpdates();
            stopHeadlessPosting();
            cancelAutoStop();
            stopForeground(true);
            stopSelf();
            releaseMediaPlayer();
            releaseWakeLock();
            return callbackId;
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
        Notification.Builder builder = new Notification.Builder(getApplicationContext())
            .setContentTitle(backgroundTitle)
            .setContentText(backgroundMessage)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_HIGH)
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

        // Set the Channel ID for Android O.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(BackgroundGeolocationService.class.getPackage().getName());
        }

        return builder.build();
    }

    // Gets the identifier of the app's resource by name, returning 0 if not found.
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
