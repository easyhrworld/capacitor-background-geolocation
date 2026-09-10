package com.easyhrworld.capacitor_background_geolocation;

import static org.junit.Assert.*;

import android.content.Context;
import android.database.sqlite.SQLiteDatabase;
import android.location.Location;
import org.json.JSONArray;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 31)
public class LocationEvidenceTest {

    private Context context;

    @Before
    public void setUp() {
        context = RuntimeEnvironment.getApplication();
        context.deleteDatabase("bg_geo_locations.db");
        context
            .getSharedPreferences("bg_geo_prefs", Context.MODE_PRIVATE)
            .edit()
            .clear()
            .putString("headless_tenant_id", "tenant")
            .putString("headless_employee_id", "alice")
            .commit();
    }

    private Location location(boolean mocked) {
        Location fix = new Location("gps");
        fix.setLatitude(19);
        fix.setLongitude(73);
        fix.setAccuracy(10);
        fix.setTime(1000);
        fix.setMock(mocked);
        return fix;
    }

    @Test
    public void preservesMockSignalAcrossReopenAndUploadBatch() throws Exception {
        assertEquals("not_detected", LocationEvidence.status(location(false)));
        LocationBuffer buffer = new LocationBuffer(context);
        buffer.insert(location(true));
        buffer.close();
        buffer = new LocationBuffer(context);
        assertEquals("mocked", buffer.getAll().getJSONObject(0).getString("mockLocationStatus"));
        JSONArray batch = buffer.getUnsyncedBatchAsJson(20);
        assertEquals("mocked", batch.getJSONObject(0).getString("mockLocationStatus"));
        buffer.markSynced(batch);
        assertEquals(0, buffer.getUnsyncedCount());
        buffer.close();
    }

    @Test
    public void upgradePreservesLegacyQueueAsUnknown() throws Exception {
        SQLiteDatabase db = context.openOrCreateDatabase("bg_geo_locations.db", Context.MODE_PRIVATE, null);
        db.execSQL(
            "CREATE TABLE buffered_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, lat REAL NOT NULL, lng REAL NOT NULL, accuracy REAL, speed REAL, bearing REAL, altitude REAL, timestamp INTEGER NOT NULL, synced INTEGER DEFAULT 0)"
        );
        db.execSQL("INSERT INTO buffered_locations (lat,lng,timestamp) VALUES (19,73,1000)");
        db.setVersion(1);
        db.close();
        LocationBuffer buffer = new LocationBuffer(context);
        JSONArray batch = buffer.getUnsyncedBatchAsJson(20);
        assertEquals(1, batch.length());
        assertEquals("unknown", batch.getJSONObject(0).getString("mockLocationStatus"));
        buffer.close();
    }

    @Test
    public void switchingEmployeeCannotUploadOrClearAnotherEmployeesEvidence() throws Exception {
        LocationBuffer buffer = new LocationBuffer(context);
        buffer.insert(location(true));
        context.getSharedPreferences("bg_geo_prefs", Context.MODE_PRIVATE).edit().putString("headless_employee_id", "bob").commit();
        assertEquals(0, buffer.getUnsyncedBatchAsJson(20).length());
        buffer.clearAll();
        context.getSharedPreferences("bg_geo_prefs", Context.MODE_PRIVATE).edit().putString("headless_employee_id", "alice").commit();
        assertEquals(1, buffer.getUnsyncedBatchAsJson(20).length());
        buffer.close();
    }
}
