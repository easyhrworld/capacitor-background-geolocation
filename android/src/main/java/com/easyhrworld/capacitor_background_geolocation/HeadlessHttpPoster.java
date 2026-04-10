package com.easyhrworld.capacitor_background_geolocation;

import android.content.Context;
import android.content.SharedPreferences;
import com.getcapacitor.Logger;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;

public class HeadlessHttpPoster {

    private static final String PREFS_NAME = "bg_geo_prefs";
    private final Context context;

    public HeadlessHttpPoster(Context context) {
        this.context = context;
    }

    public void postBatch(LocationBuffer locationBuffer) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String serverUrl = prefs.getString("headless_server_url", "");
        String authToken = prefs.getString("headless_auth_token", "");
        String employeeId = prefs.getString("headless_employee_id", "");
        String tenantId = prefs.getString("headless_tenant_id", "");
        int batchSize = prefs.getInt("headless_batch_size", 20);

        if (serverUrl.isEmpty() || authToken.isEmpty()) {
            Logger.debug("Headless posting not configured, skipping");
            return;
        }

        JSONArray batch = locationBuffer.getUnsyncedBatchAsJson(batchSize);
        if (batch.length() == 0) {
            return;
        }

        HttpURLConnection conn = null;
        try {
            JSONObject payload = new JSONObject();
            payload.put("employeeId", employeeId);
            payload.put("tenantId", tenantId);

            // Build locations array without the internal 'id' field
            JSONArray locations = new JSONArray();
            for (int i = 0; i < batch.length(); i++) {
                JSONObject src = batch.getJSONObject(i);
                JSONObject loc = new JSONObject();
                loc.put("lat", src.getDouble("lat"));
                loc.put("lng", src.getDouble("lng"));
                loc.put("accuracy", src.getDouble("accuracy"));
                loc.put("speed", src.getDouble("speed"));
                loc.put("bearing", src.getDouble("bearing"));
                loc.put("altitude", src.getDouble("altitude"));
                loc.put("timestamp", src.getLong("timestamp"));
                locations.put(loc);
            }
            payload.put("locations", locations);

            byte[] body = payload.toString().getBytes(StandardCharsets.UTF_8);

            conn = (HttpURLConnection) new URL(serverUrl).openConnection();
            conn.setRequestMethod("POST");
            conn.setRequestProperty("Authorization", "Bearer " + authToken);
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setRequestProperty("Content-Length", String.valueOf(body.length));
            conn.setConnectTimeout(30000);
            conn.setReadTimeout(30000);
            conn.setDoOutput(true);

            OutputStream os = conn.getOutputStream();
            os.write(body);
            os.flush();
            os.close();

            int responseCode = conn.getResponseCode();
            if (responseCode >= 200 && responseCode < 300) {
                Logger.info("Headless post successful: " + batch.length() + " locations");
                locationBuffer.markSynced(batch);
                locationBuffer.deleteSynced();
            } else {
                Logger.error("Headless post failed with HTTP " + responseCode);
            }
        } catch (Exception e) {
            Logger.error("Headless HTTP post error", e);
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }
}
