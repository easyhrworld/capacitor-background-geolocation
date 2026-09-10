package com.easyhrworld.capacitor_background_geolocation;

import android.location.Location;
import android.os.Build;

final class LocationEvidence {

    private LocationEvidence() {}

    @SuppressWarnings("deprecation")
    static boolean isMocked(Location location) {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? location.isMock() : location.isFromMockProvider();
    }

    static String status(Location location) {
        return isMocked(location) ? "mocked" : "not_detected";
    }
}
