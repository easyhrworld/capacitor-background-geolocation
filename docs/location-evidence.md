# Location evidence contract

`getCurrentLocation()` obtains a fresh foreground fix, with a 30-second timeout, without starting, stopping, or buffering background tracking. The host app must first obtain foreground location permission. This method does not request background permission.

`mockLocationStatus` accompanies each callback, buffered point, and native HTTP-uploaded point:

- `mocked`: Android reports a mock provider (`isMock` on API 31+, legacy `isFromMockProvider` below 31), or iOS reports software simulation.
- `not_detected`: the OS supplied a negative mock signal. This does not certify physical presence.
- `unknown`: evidence is unavailable, including records captured before this upgrade. Web always reports unknown.

The existing `simulated` boolean is retained for compatibility. Consumers making policy decisions must use the new three-state field; a legacy false value must not be treated as verified evidence.

Both SQLite buffers migrate in place. Queued fixes retain their coordinates and timestamps, and older fixes become unknown. Buffered records are scoped to the configured tenant and employee. Switching configuration cannot upload or clear another employee's queue; that employee's unsynced records remain for their next session. Native upload batches use the same owner snapshot as the upload credentials/payload. The host must stop tracking when signing out and configure the new identity before starting another session.

The iOS schema upgrade, legacy ownership backfill, and schema-version marker commit in one transaction. Failed upgrades roll back and can retry on the next buffer open. Incomplete schemas from the earlier upgrade are repaired column by column, and backfill preserves records that already have an owner. Once migration is complete, reopening does not assign unowned records to a different account.

Mock points are uploaded as evidence, rather than discarded on the device. The receiving server must authenticate the employee, enforce attendance policy, and keep the evidence separate from accepted attendance. Stopping tracking preserves unsynced evidence; `clearBufferedLocations()` intentionally deletes the current owner's queue.

## Validation

The fork incorporates Capgo upstream 8.4.5, including geofencing, permission APIs, native per-location POSTs, and its Android GPS/network provider implementation. EasyHR's `configure()` uploader retains its separate, owner-scoped durable batch queue. The optional `start({ url })` uploader is best-effort and sends a different payload; do not point it at EasyHR's batch endpoint. Both native payloads include mock-location evidence.

Android retains persisted tracking, boot recovery, and the 12-hour attendance-session limit even when no upstream `url` is configured. `minIntervalMs` controls the Android request interval and the optional per-location POST gate; it does not replace the batch upload interval. The app explicitly uses a 10-second request interval and `networkFallback: true` for gaps in GPS coverage. Network fallback only accepts fixes within 300 meters after GPS has been silent for 20 seconds. Fresh foreground captures still use the fused one-shot provider.

iOS retains the independent location tracker and now honors foreground-only requests, reports permission failures, and preserves the original session deadline across restores. Native per-location POSTs run before the saved JavaScript callback check.

Automated coverage includes Android OS mock flags, buffer reopen/persistence, old-schema migration, employee isolation, and the corresponding iOS cases. Android tests use Robolectric API 31; iOS tests use the available simulator.

iOS regression tests also cover each interrupted schema state, a failed backfill that must roll back all schema changes, retry on reopen, and preservation of ownership across account changes.

Before a store release, test physical Android devices (including one below API 31) and iPhones: real GPS, an Android mock provider, iOS developer simulation, permission denial/revocation, location services off, approximate location, no fix/timeout, active background tracking during a one-shot request, process termination, offline upload/retry, and switching accounts. Root/jailbreak bypasses and external GNSS spoofing are outside the guarantee of these OS signals.
