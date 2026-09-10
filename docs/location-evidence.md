# Location evidence contract

`getCurrentLocation()` obtains a fresh foreground fix, with a 30-second timeout, without starting, stopping, or buffering background tracking. The host app must first obtain foreground location permission. This method does not request background permission.

`mockLocationStatus` accompanies each callback, buffered point, and native HTTP-uploaded point:

- `mocked`: Android reports a mock provider (`isMock` on API 31+, legacy `isFromMockProvider` below 31), or iOS reports software simulation.
- `not_detected`: the OS supplied a negative mock signal. This does not certify physical presence.
- `unknown`: evidence is unavailable, including records captured before this upgrade. Web always reports unknown.

The existing `simulated` boolean is retained for compatibility. Consumers making policy decisions must use the new three-state field; a legacy false value must not be treated as verified evidence.

Both SQLite buffers migrate in place. Queued fixes retain their coordinates and timestamps, and older fixes become unknown. Buffered records are scoped to the configured tenant and employee. Switching configuration cannot upload or clear another employee's queue; that employee's unsynced records remain for their next session. Native upload batches use the same owner snapshot as the upload credentials/payload. The host must stop tracking when signing out and configure the new identity before starting another session.

Mock points are uploaded as evidence, rather than discarded on the device. The receiving server must authenticate the employee, enforce attendance policy, and keep the evidence separate from accepted attendance. Stopping tracking preserves unsynced evidence; `clearBufferedLocations()` intentionally deletes the current owner's queue.

## Validation

Automated coverage includes Android OS mock flags, buffer reopen/persistence, old-schema migration, employee isolation, and the corresponding iOS cases. Android tests use Robolectric API 31; iOS tests use the available simulator.

Before a store release, test physical Android devices (including one below API 31) and iPhones: real GPS, an Android mock provider, iOS developer simulation, permission denial/revocation, location services off, approximate location, no fix/timeout, active background tracking during a one-shot request, process termination, offline upload/retry, and switching accounts. Root/jailbreak bypasses and external GNSS spoofing are outside the guarantee of these OS signals.
