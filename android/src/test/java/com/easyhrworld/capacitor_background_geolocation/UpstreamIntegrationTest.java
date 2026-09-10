package com.easyhrworld.capacitor_background_geolocation;

import static org.junit.Assert.*;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.location.Location;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.PluginCall;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.android.controller.ServiceController;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 31)
public class UpstreamIntegrationTest {

    private Context context;
    private SharedPreferences prefs;
    private ServiceController<BackgroundGeolocationService> controller;

    @Before
    public void setUp() {
        context = RuntimeEnvironment.getApplication();
        context.deleteDatabase("bg_geo_locations.db");
        prefs = context.getSharedPreferences("bg_geo_prefs", Context.MODE_PRIVATE);
        prefs.edit().clear().putString("headless_tenant_id", "tenant").putString("headless_employee_id", "alice").commit();
        LocationStore.clear(context);
    }

    @After
    public void tearDown() throws Exception {
        if (controller != null) {
            Field field = BackgroundGeolocationService.class.getDeclaredField("headlessExecutor");
            field.setAccessible(true);
            ExecutorService executor = (ExecutorService) field.get(controller.get());
            controller.destroy();
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS));
        }
    }

    @Test
    public void nativeDeliveryAndDurableQueuePreserveMockEvidence() throws Exception {
        controller = Robolectric.buildService(BackgroundGeolocationService.class).create();
        Location location = new Location("gps");
        location.setLatitude(19);
        location.setLongitude(73);
        location.setTime(1000);
        location.setMock(true);
        BackgroundGeolocationService.createLocationListener(controller.get()).onLocationChanged(location);
        try (LocationBuffer buffer = new LocationBuffer(context)) {
            assertEquals("mocked", buffer.getAll().getJSONObject(0).getString("mockLocationStatus"));
        }
        Method serialize = BackgroundGeolocationService.class.getDeclaredMethod("locationToJson", Location.class);
        serialize.setAccessible(true);
        JSONObject payload = (JSONObject) serialize.invoke(null, location);
        assertEquals("mocked", payload.getString("mockLocationStatus"));
        assertEquals("native", payload.getString("source"));
        assertTrue(payload.getBoolean("simulated"));
    }

    @Test
    public void restoresHeadlessTrackingWithoutAnUpstreamPostUrlAndStopsAfterRebind() {
        prefs.edit().putBoolean("is_tracking", true).putLong("tracking_start_time", System.currentTimeMillis()).commit();
        controller = Robolectric.buildService(BackgroundGeolocationService.class).create();
        BackgroundGeolocationService service = controller.get();
        assertEquals(Service.START_STICKY, service.onStartCommand(null, 0, 1));
        assertFalse(LocationStore.isEnabled(context));
        assertTrue(service.onUnbind(new Intent()));
        assertTrue(prefs.getBoolean("is_tracking", false));
        BackgroundGeolocationService.LocalBinder binder = (BackgroundGeolocationService.LocalBinder) service.onBind(new Intent());
        binder.stop();
        assertFalse(prefs.getBoolean("is_tracking", true));
    }

    @Test
    public void expiredSessionDoesNotRestartOrLeaveAnUpstreamUrlEnabled() {
        prefs.edit().putBoolean("is_tracking", true).putLong("tracking_start_time", System.currentTimeMillis() - 43200001L).commit();
        LocationStore.saveSetup(context, "https://example.invalid/location", "Tracking", "Tracking", 50, null, 0, false);
        controller = Robolectric.buildService(BackgroundGeolocationService.class).create();
        assertEquals(Service.START_NOT_STICKY, controller.get().onStartCommand(null, 0, 1));
        assertFalse(prefs.getBoolean("is_tracking", true));
        assertFalse(LocationStore.isEnabled(context));
    }

    @Test
    public void initialStartRemainsStickyBeforeBinderPersistsTracking() {
        controller = Robolectric.buildService(BackgroundGeolocationService.class).create();
        assertEquals(Service.START_STICKY, controller.get().onStartCommand(new Intent(), 0, 1));
    }

    @Test
    public void permissionDenialResolvesWithoutRequestingTheSamePermissionAgain() throws Exception {
        DenyingPlugin plugin = new DenyingPlugin();
        RecordingCall call = new RecordingCall();
        plugin.requestPermissions(call);
        assertEquals(List.of("location"), plugin.requested);
        Method callback = BackgroundGeolocation.class.getDeclaredMethod("generalLocationPermissionsCallback", PluginCall.class);
        callback.setAccessible(true);
        callback.invoke(plugin, call);
        assertEquals(List.of("location"), plugin.requested);
        assertEquals("denied", call.result.getString("location"));
    }

    @Test
    public void backgroundPermissionDenialResolvesWithoutRequestingAgain() throws Exception {
        DenyingPlugin plugin = new DenyingPlugin();
        plugin.foregroundGranted = true;
        RecordingCall call = new RecordingCall();
        plugin.requestPermissions(call);
        assertEquals(List.of("backgroundLocation"), plugin.requested);
        Method callback = BackgroundGeolocation.class.getDeclaredMethod("generalBackgroundPermissionsCallback", PluginCall.class);
        callback.setAccessible(true);
        callback.invoke(plugin, call);
        assertEquals(List.of("backgroundLocation"), plugin.requested);
        assertEquals("denied", call.result.getString("backgroundLocation"));
    }

    private static class RecordingCall extends PluginCall {

        JSObject result;

        RecordingCall() {
            super(null, "BackgroundGeolocation", "test", "requestPermissions", new JSObject());
        }

        @Override
        public void resolve(JSObject data) {
            result = data;
        }
    }

    private static class DenyingPlugin extends BackgroundGeolocation {

        final List<String> requested = new ArrayList<>();
        boolean foregroundGranted;

        @Override
        public PermissionState getPermissionState(String alias) {
            return foregroundGranted && "location".equals(alias) ? PermissionState.GRANTED : PermissionState.DENIED;
        }

        @Override
        protected void requestPermissionForAlias(String alias, PluginCall call, String callbackName) {
            requested.add(alias);
        }
    }
}
