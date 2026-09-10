package com.easyhrworld.capacitor_background_geolocation;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.location.Location;
import com.getcapacitor.Logger;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

public class LocationBuffer extends SQLiteOpenHelper {

    private static final String DB_NAME = "bg_geo_locations.db";
    private static final int DB_VERSION = 2;
    private final Context context;
    private static final String OWNER_FILTER = "ownerTenant = ? AND ownerEmployee = ?";
    private static final String TABLE = "buffered_locations";

    public LocationBuffer(Context context) {
        super(context, DB_NAME, null, DB_VERSION);
        this.context = context.getApplicationContext();
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL(
            "CREATE TABLE " +
                TABLE +
                " (" +
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                "lat REAL NOT NULL, " +
                "lng REAL NOT NULL, " +
                "accuracy REAL, " +
                "speed REAL, " +
                "bearing REAL, " +
                "altitude REAL, " +
                "timestamp INTEGER NOT NULL, " +
                "synced INTEGER DEFAULT 0, " +
                "mockLocationStatus TEXT NOT NULL DEFAULT 'unknown', " +
                "ownerTenant TEXT NOT NULL DEFAULT '', ownerEmployee TEXT NOT NULL DEFAULT ''" +
                ")"
        );
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE " + TABLE + " ADD COLUMN mockLocationStatus TEXT NOT NULL DEFAULT 'unknown'");
            db.execSQL("ALTER TABLE " + TABLE + " ADD COLUMN ownerTenant TEXT NOT NULL DEFAULT ''");
            db.execSQL("ALTER TABLE " + TABLE + " ADD COLUMN ownerEmployee TEXT NOT NULL DEFAULT ''");
            String[] owner = owner();
            ContentValues values = new ContentValues();
            values.put("ownerTenant", owner[0]);
            values.put("ownerEmployee", owner[1]);
            db.update(TABLE, values, null, null);
        }
    }

    public void insert(Location location) {
        try {
            SQLiteDatabase db = getWritableDatabase();
            ContentValues values = new ContentValues();
            values.put("lat", location.getLatitude());
            values.put("lng", location.getLongitude());
            values.put("accuracy", location.hasAccuracy() ? location.getAccuracy() : 0);
            values.put("speed", location.hasSpeed() ? location.getSpeed() : 0);
            values.put("bearing", location.hasBearing() ? location.getBearing() : 0);
            values.put("altitude", location.hasAltitude() ? location.getAltitude() : 0);
            values.put("timestamp", location.getTime());
            values.put("synced", 0);
            values.put("mockLocationStatus", LocationEvidence.status(location));
            String[] owner = owner();
            values.put("ownerTenant", owner[0]);
            values.put("ownerEmployee", owner[1]);
            db.insert(TABLE, null, values);
        } catch (Exception e) {
            Logger.error("Failed to buffer location", e);
        }
    }

    public List<long[]> getUnsyncedBatch(int batchSize) {
        List<long[]> batch = new ArrayList<>();
        try {
            SQLiteDatabase db = getReadableDatabase();
            Cursor cursor = db.query(
                TABLE,
                null,
                "synced = 0 AND " + OWNER_FILTER,
                owner(),
                null,
                null,
                "id ASC",
                String.valueOf(batchSize)
            );
            while (cursor.moveToNext()) {
                long[] row = new long[] { cursor.getLong(cursor.getColumnIndexOrThrow("id")) };
                batch.add(row);
            }
            cursor.close();
        } catch (Exception e) {
            Logger.error("Failed to get unsynced batch", e);
        }
        return batch;
    }

    public JSONArray getUnsyncedBatchAsJson(int batchSize) {
        return getUnsyncedBatchAsJson(batchSize, owner());
    }

    public JSONArray getUnsyncedBatchAsJson(int batchSize, String[] owner) {
        JSONArray arr = new JSONArray();
        try {
            SQLiteDatabase db = getReadableDatabase();
            Cursor cursor = db.query(TABLE, null, "synced = 0 AND " + OWNER_FILTER, owner, null, null, "id ASC", String.valueOf(batchSize));
            while (cursor.moveToNext()) {
                JSONObject obj = new JSONObject();
                obj.put("id", cursor.getLong(cursor.getColumnIndexOrThrow("id")));
                obj.put("lat", cursor.getDouble(cursor.getColumnIndexOrThrow("lat")));
                obj.put("lng", cursor.getDouble(cursor.getColumnIndexOrThrow("lng")));
                obj.put("accuracy", cursor.getDouble(cursor.getColumnIndexOrThrow("accuracy")));
                obj.put("speed", cursor.getDouble(cursor.getColumnIndexOrThrow("speed")));
                obj.put("bearing", cursor.getDouble(cursor.getColumnIndexOrThrow("bearing")));
                obj.put("altitude", cursor.getDouble(cursor.getColumnIndexOrThrow("altitude")));
                obj.put("timestamp", cursor.getLong(cursor.getColumnIndexOrThrow("timestamp")));
                obj.put("mockLocationStatus", cursor.getString(cursor.getColumnIndexOrThrow("mockLocationStatus")));
                arr.put(obj);
            }
            cursor.close();
        } catch (Exception e) {
            Logger.error("Failed to get unsynced batch as JSON", e);
        }
        return arr;
    }

    public void markSynced(JSONArray locations) {
        try {
            SQLiteDatabase db = getWritableDatabase();
            db.beginTransaction();
            for (int i = 0; i < locations.length(); i++) {
                JSONObject loc = locations.getJSONObject(i);
                long id = loc.getLong("id");
                ContentValues values = new ContentValues();
                values.put("synced", 1);
                db.update(TABLE, values, "id = ?", new String[] { String.valueOf(id) });
            }
            db.setTransactionSuccessful();
            db.endTransaction();
        } catch (Exception e) {
            Logger.error("Failed to mark locations as synced", e);
        }
    }

    public void deleteSynced() {
        try {
            SQLiteDatabase db = getWritableDatabase();
            db.delete(TABLE, "synced = 1", null);
        } catch (Exception e) {
            Logger.error("Failed to delete synced locations", e);
        }
    }

    public JSONArray getAll() {
        JSONArray arr = new JSONArray();
        try {
            SQLiteDatabase db = getReadableDatabase();
            Cursor cursor = db.query(TABLE, null, OWNER_FILTER, owner(), null, null, "id ASC");
            while (cursor.moveToNext()) {
                JSONObject obj = new JSONObject();
                obj.put("lat", cursor.getDouble(cursor.getColumnIndexOrThrow("lat")));
                obj.put("lng", cursor.getDouble(cursor.getColumnIndexOrThrow("lng")));
                obj.put("accuracy", cursor.getDouble(cursor.getColumnIndexOrThrow("accuracy")));
                obj.put("speed", cursor.getDouble(cursor.getColumnIndexOrThrow("speed")));
                obj.put("bearing", cursor.getDouble(cursor.getColumnIndexOrThrow("bearing")));
                obj.put("altitude", cursor.getDouble(cursor.getColumnIndexOrThrow("altitude")));
                obj.put("timestamp", cursor.getLong(cursor.getColumnIndexOrThrow("timestamp")));
                obj.put("mockLocationStatus", cursor.getString(cursor.getColumnIndexOrThrow("mockLocationStatus")));
                arr.put(obj);
            }
            cursor.close();
        } catch (Exception e) {
            Logger.error("Failed to get all locations", e);
        }
        return arr;
    }

    public void clearAll() {
        try {
            SQLiteDatabase db = getWritableDatabase();
            db.delete(TABLE, OWNER_FILTER, owner());
        } catch (Exception e) {
            Logger.error("Failed to clear all locations", e);
        }
    }

    private String[] owner() {
        android.content.SharedPreferences prefs = context.getSharedPreferences("bg_geo_prefs", Context.MODE_PRIVATE);
        java.util.Map<String, ?> snapshot = prefs.getAll();
        return new String[] {
            snapshot.get("headless_tenant_id") instanceof String ? (String) snapshot.get("headless_tenant_id") : "",
            snapshot.get("headless_employee_id") instanceof String ? (String) snapshot.get("headless_employee_id") : ""
        };
    }

    public int getUnsyncedCount() {
        int count = 0;
        try {
            SQLiteDatabase db = getReadableDatabase();
            Cursor cursor = db.rawQuery("SELECT COUNT(*) FROM " + TABLE + " WHERE synced = 0 AND " + OWNER_FILTER, owner());
            if (cursor.moveToFirst()) {
                count = cursor.getInt(0);
            }
            cursor.close();
        } catch (Exception e) {
            Logger.error("Failed to get unsynced count", e);
        }
        return count;
    }
}
