package com.easyhrworld.capacitor_background_geolocation;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import androidx.core.content.ContextCompat;
import com.getcapacitor.Logger;

public class BootReceiver extends BroadcastReceiver {

    private static final String PREFS_NAME = "bg_geo_prefs";
    private static final long MAX_TRACKING_DURATION_MS = 12 * 60 * 60 * 1000L;

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            return;
        }

        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        boolean wasTracking = prefs.getBoolean("is_tracking", false);

        if (!wasTracking) {
            return;
        }

        long trackingStartTime = prefs.getLong("tracking_start_time", 0);
        long elapsed = System.currentTimeMillis() - trackingStartTime;

        if (elapsed >= MAX_TRACKING_DURATION_MS) {
            Logger.info("Boot receiver: tracking exceeded 12-hour limit, not restarting");
            prefs.edit().putBoolean("is_tracking", false).apply();
            return;
        }

        Logger.info("Boot receiver: restarting background geolocation service");
        Intent serviceIntent = new Intent(context, BackgroundGeolocationService.class);
        serviceIntent.putExtra("from_boot", true);
        ContextCompat.startForegroundService(context, serviceIntent);
    }
}
