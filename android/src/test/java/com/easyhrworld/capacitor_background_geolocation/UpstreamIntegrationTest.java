package com.easyhrworld.capacitor_background_geolocation;

import static org.junit.Assert.*;
import static org.robolectric.Shadows.shadowOf;

import android.app.Application;
import android.app.Service;
import android.content.ComponentName;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.SharedPreferences;
import android.location.Location;
import android.os.Looper;
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
    public void coldStopDoesNotStartAForegroundServiceAndPreservesEvidence() throws Exception {
        assertStopRebindsWithoutStarting(false);
    }

    @Test
    public void headlessStopRebindsWithoutStartingAnotherForegroundService() throws Exception {
        assertStopRebindsWithoutStarting(true);
    }

    private void assertStopRebindsWithoutStarting(boolean tracking) throws Exception {
        prefs.edit().putBoolean("is_tracking", tracking).putLong("tracking_start_time", System.currentTimeMillis()).commit();
        Location point = new Location("gps");
        point.setLatitude(19);
        point.setLongitude(73);
        point.setTime(1000);
        point.setMock(true);
        try (LocationBuffer buffer = new LocationBuffer(context)) {
            buffer.insert(point);
        }
        controller = Robolectric.buildService(BackgroundGeolocationService.class).create();
        if (tracking) controller.get().onStartCommand(null, 0, 1);
        shadowOf((Application) context).setComponentNameAndServiceForBindService(
            new ComponentName(context, BackgroundGeolocationService.class),
            controller.get().onBind(new Intent())
        );
        RecordingCall call = new RecordingCall();
        new ContextPlugin().stop(call);
        shadowOf(Looper.getMainLooper()).idle();
        assertTrue(call.resolved);
        assertFalse(prefs.getBoolean("is_tracking", true));
        try (LocationBuffer buffer = new LocationBuffer(context)) {
            assertEquals(1, buffer.getAll().length());
        }
    }

    @Test
    public void clearingTheTokenPreservesQueueOwnerAndOtherHeadlessSettings() {
        prefs
            .edit()
            .putString("headless_auth_token", "old-token")
            .putString("headless_server_url", "https://example.invalid")
            .putInt("headless_batch_size", 7)
            .putInt("headless_post_interval", 30000)
            .commit();
        RecordingCall call = new RecordingCall(new JSObject().put("authToken", ""));
        new ContextPlugin().configure(call);
        assertTrue(call.resolved);
        assertEquals("", prefs.getString("headless_auth_token", null));
        assertEquals("tenant", prefs.getString("headless_tenant_id", null));
        assertEquals("alice", prefs.getString("headless_employee_id", null));
        assertEquals("https://example.invalid", prefs.getString("headless_server_url", null));
        assertEquals(7, prefs.getInt("headless_batch_size", 0));
        assertEquals(30000, prefs.getInt("headless_post_interval", 0));
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
        boolean resolved;

        RecordingCall() {
            this(new JSObject());
        }

        RecordingCall(JSObject data) {
            super(null, "BackgroundGeolocation", "test", "requestPermissions", data);
        }

        @Override
        public void resolve() {
            resolved = true;
        }

        @Override
        public void resolve(JSObject data) {
            result = data;
        }
    }

    private class ContextPlugin extends BackgroundGeolocation {

        @Override
        public Context getContext() {
            return new ContextWrapper(context) {
                @Override
                public ComponentName startForegroundService(Intent intent) {
                    throw new AssertionError("Stopping must not start a foreground service");
                }

                @Override
                public ComponentName startService(Intent intent) {
                    throw new AssertionError("Stopping must not start a service");
                }
            };
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
