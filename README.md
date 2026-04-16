# Background Geolocation
 <a href="https://capgo.app/"><img src='https://raw.githubusercontent.com/Cap-go/capgo/main/assets/capgo_banner.png' alt='Capgo - Instant updates for capacitor'/></a>

<div align="center">
  <h2><a href="https://capgo.app/?ref=plugin_background_geolocation"> ➡️ Get Instant updates for your App with Capgo</a></h2>
  <h2><a href="https://capgo.app/consulting/?ref=plugin_background_geolocation"> Missing a feature? We’ll build the plugin for you 💪</a></h2>
</div>

A Capacitor plugin that lets you receive accurate geolocation updates even while the app is backgrounded.
It has a web API to facilitate for a similar usage, but background geolocation is not supported in a regular browser, only in an app environment.

## This plugin's history

Interestingly enough, this plugin has a lot of history. The initial solution from [Transistorsoft](https://github.com/transistorsoft) was a great piece of software, and I ([HarelM](https://github.com/HarelM)) encourage using it if it fits your needs.  
I tried it and understood that it prioritizes battery life over accuracy, which wasn't the right fit for my hiking app.  
There was a very good fork maintained by **mauron85** specifically for that use case, and I was happy to help maintain it.  
But at some point, **mauron85** stopped responding to messages on GitHub, and no one could continue maintaining it.  
I hope mauron85 is safe and sound somewhere.  

So I created a fork and started maintaining it [here](https://github.com/HaylLtd/cordova-background-geolocation-plugin).  
It served me well for over half a decade, but I felt it was hard to maintain due to all its history, features, and bug fixes.  
I also felt like there was a barrier to introducing new features because of its complexity.

So I started exploring what it would take to reduce that complexity—at the same time, I was envious of how small [`@capacitor-community/background-geolocation`](https://github.com/capacitor-community/background-geolocation) is.  
I took the best of both worlds: tried to reduce the codebase in the original Cordova plugin and add some robustness to the Capacitor plugin.  

That's how I ended up maintaining this one.  
I hope you'll enjoy it!


## Plugin comparison

A short comparison between the three main background-geolocation plugins commonly used in Capacitor apps.

| Plugin | Accuracy | Background | HTTP Upload | Pricing |
|--------|----------|------------|-------------|---------|
| `@capacitor-community/background-geolocation` (Community) | Not accurate | Yes | No | Free |
| `@capgo/background-geolocation` (this plugin) | Accurate | Yes | No | Free |
| Transistorsoft (original) | Accurate | Yes | Yes — built-in HTTP uploader to your API | Paid |

Notes:
- The Community plugin is lightweight and continues to work in the background, but it is known to be less accurate than the options below.
- This Cap-go plugin aims to provide accurate location fixes and reliable background operation without requiring a paid license.
- Transistorsoft's plugin is a mature, accurate solution that also includes an HTTP uploader (it can send location updates to your API). It is a commercial product and requires a paid license for full use.


## Usage

```javascript
import { BackgroundGeolocation } from "@capgo/background-geolocation";

BackgroundGeolocation.start(
    {
        backgroundMessage: "Cancel to prevent battery drain.",
        backgroundTitle: "Tracking You.",
        requestPermissions: true,
        stale: false,
        distanceFilter: 50
    },
    (location, error) => {
        if (error) {
            if (error.code === "NOT_AUTHORIZED") {
                if (window.confirm(
                    "This app needs your location, " +
                    "but does not have permission.\n\n" +
                    "Open settings now?"
                )) {
                    // It can be useful to direct the user to their device's
                    // settings when location permissions have been denied. The
                    // plugin provides the 'openSettings' method to do exactly
                    // this.
                    BackgroundGeolocation.openSettings();
                }
            }
            return console.error(error);
        }
        return console.log(location);
    }
).then(() => {
    // When location updates are no longer needed, the plugin should be stopped by calling
    BackgroundGeolocation.stop();
});

// Set a planned route to get a notification sound when a new location arrives and it's not on the route:
        
BackgroundGeolocation.setPlannedRoute({soundFile: "assets/myFile.mp3", route: [[1,2], [3,4]], distance: 30 });

// If you just want the current location, try something like this. The longer
// the timeout, the more accurate the guess will be. I wouldn't go below about 100ms.
function guessLocation(callback, timeout) {
    let last_location;
    BackgroundGeolocation.start(
        {
            requestPermissions: false,
            stale: true
        },
        (location) => {
            last_location = location || undefined;
        }
    ).then(() => {
        setTimeout(() => {
            callback(last_location);
            BackgroundGeolocation.stop();
        }, timeout);
    });
}
```

## Documentation

The most complete doc is available here: https://capgo.app/docs/plugins/background-geolocation/

## Compatibility

| Plugin version | Capacitor compatibility | Maintained |
| -------------- | ----------------------- | ---------- |
| v8.\*.\*       | v8.\*.\*                | ✅          |
| v7.\*.\*       | v7.\*.\*                | On demand   |
| v6.\*.\*       | v6.\*.\*                | ❌          |
| v5.\*.\*       | v5.\*.\*                | ❌          |

> **Note:** The major version of this plugin follows the major version of Capacitor. Use the version that matches your Capacitor installation (e.g., plugin v8 for Capacitor 8). Only the latest major version is actively maintained.

## Installation

This plugin supports Capacitor v7:

| Capacitor  | Plugin |
|------------|--------|
| v7         | v7     |

```sh
npm install @capgo/background-geolocation
npx cap update
```

### iOS
Add the following keys to `Info.plist.`:

```xml
<dict>
  ...
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>We need to track your location</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
  <string>We need to track your location while your device is locked.</string>
  <key>UIBackgroundModes</key>
  <array>
    <string>location</string>
  </array>
  ...
</dict>
```

### Android

Set the the `android.useLegacyBridge` option to `true` in your Capacitor configuration. This prevents location updates halting after 5 minutes in the background. See https://capacitorjs.com/docs/config and https://github.com/capacitor-community/background-geolocation/issues/89.

On Android 13+, the app needs the `POST_NOTIFICATIONS` runtime permission to show the persistent notification informing the user that their location is being used in the background. This runtime permission is requested after the location permission is granted.

If your app forwards location updates to a server in real time, be aware that after 5 minutes in the background Android will throttle HTTP requests initiated from the WebView. The solution is to use a native HTTP plugin such as [CapacitorHttp](https://capacitorjs.com/docs/apis/http). See https://github.com/capacitor-community/background-geolocation/issues/14.

Configuration specific to Android can be made in `strings.xml`:
```xml
<resources>
    <!--
        The channel name for the background notification. This will be visible
        when the user presses & holds the notification. It defaults to
        "Background Tracking".
    -->
    <string name="capacitor_background_geolocation_notification_channel_name">
        Background Tracking
    </string>

    <!--
        The icon to use for the background notification. Note the absence of a
        leading "@". It defaults to "mipmap/ic_launcher", the app's launch icon.

        If a raster image is used to generate the icon (as opposed to a vector
        image), it must have a transparent background. To make sure your image
        is compatible, select "Notification Icons" as the Icon Type when
        creating the image asset in Android Studio.

        An incompatible image asset will cause the notification to misbehave in
        a few telling ways, even if the icon appears correctly:

          - The notification may be dismissable by the user when it should not
            be.
          - Tapping the notification may open the settings, not the app.
          - The notification text may be incorrect.
    -->
    <string name="capacitor_background_geolocation_notification_icon">
        drawable/ic_tracking
    </string>

    <!--
        The color of the notification as a string parseable by
        android.graphics.Color.parseColor. Optional.
    -->
    <string name="capacitor_background_geolocation_notification_color">
        yellow
    </string>
</resources>

```

## API

<docgen-index>

* [`start(...)`](#start)
* [`stop()`](#stop)
* [`openSettings()`](#opensettings)
* [`setPlannedRoute(...)`](#setplannedroute)
* [`getPluginVersion()`](#getpluginversion)
* [`configure(...)`](#configure)
* [`getBufferedLocations()`](#getbufferedlocations)
* [`clearBufferedLocations()`](#clearbufferedlocations)
* [`getAuthorizationStatus()`](#getauthorizationstatus)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

Main plugin interface for background geolocation functionality.

### start(...)

```typescript
start(options: StartOptions, callback: (position?: Location | undefined, error?: CallbackError | undefined) => void) => Promise<void>
```

Start listening for location changes. The callback is invoked
each time a new location is available.

| Param          | Type                                                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **`options`**  | <code><a href="#startoptions">StartOptions</a></code>                                                                     |
| **`callback`** | <code>(position?: <a href="#location">Location</a>, error?: <a href="#callbackerror">CallbackError</a>) =&gt; void</code> |

**Since:** 7.0.9

--------------------


### stop()

```typescript
stop() => Promise<void>
```

Stop location updates and the background service.

**Since:** 7.0.9

--------------------


### openSettings()

```typescript
openSettings() => Promise<void>
```

Opens the device's location settings page.

**Since:** 7.0.0

--------------------


### setPlannedRoute(...)

```typescript
setPlannedRoute(options: SetPlannedRouteOptions) => Promise<void>
```

Set a planned route with audio alert on deviation.

| Param         | Type                                                                      |
| ------------- | ------------------------------------------------------------------------- |
| **`options`** | <code><a href="#setplannedrouteoptions">SetPlannedRouteOptions</a></code> |

**Since:** 7.0.11

--------------------


### getPluginVersion()

```typescript
getPluginVersion() => Promise<{ version: string; }>
```

Get the native Capacitor plugin version.

**Returns:** <code>Promise&lt;{ version: string; }&gt;</code>

--------------------


### configure(...)

```typescript
configure(config: HeadlessConfig) => Promise<void>
```

Configure headless mode for native HTTP posting of location
batches to a server endpoint. Call this before start() or
whenever the auth token needs refreshing.

| Param        | Type                                                      |
| ------------ | --------------------------------------------------------- |
| **`config`** | <code><a href="#headlessconfig">HeadlessConfig</a></code> |

**Since:** 1.0.0

--------------------


### getBufferedLocations()

```typescript
getBufferedLocations() => Promise<{ locations: BufferedLocation[]; }>
```

Get all locations buffered locally on the device.

**Returns:** <code>Promise&lt;{ locations: BufferedLocation[]; }&gt;</code>

**Since:** 1.0.0

--------------------


### clearBufferedLocations()

```typescript
clearBufferedLocations() => Promise<void>
```

Clear all locally buffered locations.

**Since:** 1.0.0

--------------------


### getAuthorizationStatus()

```typescript
getAuthorizationStatus() => Promise<{ status: 'notDetermined' | 'whenInUse' | 'always' | 'denied' | 'restricted'; }>
```

Get the current native location authorization status.

- `notDetermined` — user has never been asked (iOS) or permission hasn't been requested (Android)
- `whenInUse` — user allowed location only while using the app (iOS) / foreground only (Android)
- `always` — user allowed location all the time (iOS) / background granted (Android)
- `denied` — user denied location access
- `restricted` — location is restricted by parental controls or MDM (iOS only)

Use this to detect whether to show an in-app prompt asking the user to upgrade
from "While Using" to "Always" via Settings.

**Returns:** <code>Promise&lt;{ status: 'notDetermined' | 'whenInUse' | 'always' | 'denied' | 'restricted'; }&gt;</code>

**Since:** 1.0.0

--------------------


### Interfaces


#### StartOptions

The options for configuring for location updates.

| Prop                        | Type                 | Description                                                                                                                                                                                                                                                                                                                                                                                                          | Default                            | Since |
| --------------------------- | -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- | ----- |
| **`backgroundMessage`**     | <code>string</code>  | If the "backgroundMessage" option is defined, the plugin will provide location updates whether the app is in the background or the foreground. If it is not defined, location updates are only guaranteed in the foreground. This is true on both platforms. On Android, a notification must be shown to continue receiving location updates in the background. This option specifies the text of that notification. |                                    | 7.0.9 |
| **`backgroundTitle`**       | <code>string</code>  | The title of the notification mentioned above.                                                                                                                                                                                                                                                                                                                                                                       | <code>"Using your location"</code> | 7.0.9 |
| **`requestPermissions`**    | <code>boolean</code> | Whether permissions should be requested from the user automatically, if they are not already granted.                                                                                                                                                                                                                                                                                                                | <code>true</code>                  | 7.0.9 |
| **`stale`**                 | <code>boolean</code> | If "true", stale locations may be delivered while the device obtains a GPS fix. You are responsible for checking the "time" property. If "false", locations are guaranteed to be up to date.                                                                                                                                                                                                                         | <code>false</code>                 | 7.0.9 |
| **`distanceFilter`**        | <code>number</code>  | The distance in meters that the device must move before a new location update is triggered.                                                                                                                                                                                                                                                                                                                          | <code>0</code>                     | 7.0.9 |
| **`stopOnTerminate`**       | <code>boolean</code> | If false, the service will continue running after the app is terminated.                                                                                                                                                                                                                                                                                                                                             | <code>false</code>                 | 1.0.0 |
| **`startOnBoot`**           | <code>boolean</code> | If true, the service will restart after a device reboot if it was running before the reboot.                                                                                                                                                                                                                                                                                                                         | <code>true</code>                  | 1.0.0 |
| **`maxTrackingDurationMs`** | <code>number</code>  | Maximum tracking duration in milliseconds. The service will auto-stop after this duration to prevent indefinite battery drain if the user forgets to check out.                                                                                                                                                                                                                                                      | <code>43200000 (12 hours)</code>   | 1.0.0 |


#### Location

Represents a geographical location with various attributes.

| Prop                   | Type                        | Description                                                                     | Since |
| ---------------------- | --------------------------- | ------------------------------------------------------------------------------- | ----- |
| **`latitude`**         | <code>number</code>         | Latitude in degrees. Range: -90.0 to +90.0                                      | 7.0.0 |
| **`longitude`**        | <code>number</code>         | Longitude in degrees. Range: -180.0 to +180.0                                   | 7.0.0 |
| **`accuracy`**         | <code>number</code>         | Radius of horizontal uncertainty in metres, with 68% confidence.                | 7.0.0 |
| **`altitude`**         | <code>number \| null</code> | Metres above sea level (or null if not available).                              | 7.0.0 |
| **`altitudeAccuracy`** | <code>number \| null</code> | Vertical uncertainty in metres, with 68% confidence (or null if not available). | 7.0.0 |
| **`simulated`**        | <code>boolean</code>        | `true` if the location was simulated by software, rather than GPS.              | 7.0.0 |
| **`bearing`**          | <code>number \| null</code> | Deviation from true north in degrees (or null if not available).                | 7.0.0 |
| **`speed`**            | <code>number \| null</code> | Speed in metres per second (or null if not available).                          | 7.0.0 |
| **`time`**             | <code>number \| null</code> | Time the location was produced, in milliseconds since the unix epoch.           | 7.0.0 |


#### CallbackError

Error object that may be passed to the location start callback.

| Prop       | Type                | Description                                           | Since |
| ---------- | ------------------- | ----------------------------------------------------- | ----- |
| **`code`** | <code>string</code> | Optional error code for more specific error handling. | 7.0.0 |


#### SetPlannedRouteOptions

| Prop            | Type                            | Description                                                                                         | Default         | Since  |
| --------------- | ------------------------------- | --------------------------------------------------------------------------------------------------- | --------------- | ------ |
| **`soundFile`** | <code>string</code>             | The name of the sound file to play. Must be a valid sound relative path in the app's public folder. |                 | 7.0.10 |
| **`route`**     | <code>[number, number][]</code> | The planned route as an array of longitude and latitude pairs.                                      |                 | 7.0.11 |
| **`distance`**  | <code>number</code>             | The distance in meters to deviate before triggering the sound.                                      | <code>50</code> | 7.0.11 |


#### HeadlessConfig

Configuration for headless mode — native HTTP posting of location
batches to a server endpoint without the WebView being alive.

| Prop                 | Type                                                            | Description                                             | Default            | Since |
| -------------------- | --------------------------------------------------------------- | ------------------------------------------------------- | ------------------ | ----- |
| **`serverUrl`**      | <code>string</code>                                             | The server URL to POST location batches to.             |                    | 1.0.0 |
| **`authToken`**      | <code>string</code>                                             | JWT Bearer token for authentication.                    |                    | 1.0.0 |
| **`employeeId`**     | <code>string</code>                                             | Employee identifier included in the POST payload.       |                    | 1.0.0 |
| **`tenantId`**       | <code>string</code>                                             | Tenant identifier included in the POST payload.         |                    | 1.0.0 |
| **`headers`**        | <code><a href="#record">Record</a>&lt;string, string&gt;</code> | Additional HTTP headers to include in the POST request. |                    | 1.0.0 |
| **`batchSize`**      | <code>number</code>                                             | Number of locations to include in each batch POST.      | <code>20</code>    | 1.0.0 |
| **`postIntervalMs`** | <code>number</code>                                             | Interval in milliseconds between batch POST attempts.   | <code>60000</code> | 1.0.0 |


#### BufferedLocation

A buffered location record stored locally on the device.

| Prop            | Type                |
| --------------- | ------------------- |
| **`lat`**       | <code>number</code> |
| **`lng`**       | <code>number</code> |
| **`accuracy`**  | <code>number</code> |
| **`speed`**     | <code>number</code> |
| **`bearing`**   | <code>number</code> |
| **`altitude`**  | <code>number</code> |
| **`timestamp`** | <code>number</code> |


### Type Aliases


#### Record

Construct a type with a set of properties K of type T

<code>{ [P in K]: T; }</code>

</docgen-api>
