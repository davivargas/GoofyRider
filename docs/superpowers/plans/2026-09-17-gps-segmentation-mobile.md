# GPS Segmentation Mobile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send barometric pressure with every recorded fix, carry it through local storage and upload, and show the backend's real session statistics (including the new break stats) instead of zeros.

**Architecture:** The native Android bridge samples the pressure sensor while location updates run and stamps `pressureHpa` on each fix; Dart carries it through `LocationSample`, `LocalSessionPoint`, the Drift `local_session_points` table (schema version 5), and the batch upload body. Remote session parsing maps the backend `SessionSummary` fields the API actually sends (descent duration, descent distance, average descent speed, lift and descent vertical, break count and duration) into `LocalRideSession`, which also gains two break fields persisted in `local_ride_sessions`; the detail screen shows one new "Breaks" stat. The transitional Dart pipeline is not touched. Plan 3 of 3; plan 2 (backend) must be merged first because the contract fixtures come from it.

**Tech Stack:** Flutter, Riverpod, Drift (raw SQL DAOs), Dio, Kotlin (Android bridge), flutter_test, mocktail.

**Spec:** `docs/superpowers/specs/2026-09-13-gps-segmentation-design.md` (sections 4.1, 4.2, 10 bind this plan). Spec deviation, recorded here: section 10 asks for "one row" showing breaks; that row is only meaningful if the summary fields it sits next to are mapped, and today the app reads field names the API never sends (`duration_s`, `distance_m`, `avg_speed_mps`, `elevation_gain_m`, `elevation_loss_m`; see the 2026-09-12 audit, finding H4). Task 3 therefore maps the real summary fields as well.

## Global Constraints

- Work on the branch the controller names, in the worktree it names. Run `git branch --show-current` before every commit. Never run `git stash`, `git checkout`, `git switch`, `git restore`, `git reset`, `git clean`, `git merge`, or `git rebase`; compare with `git show <rev>:<path>` or `git diff`; stage with explicit `git add <paths>`.
- Mobile layering `presentation -> domain -> data`; widgets never call Dio or Drift; persistence goes through DAOs; providers stay at feature root; nothing under `presentation/` imports Dio or Drift. No classification logic is added on mobile (spec: the backend analyzer is the truth); the `features/session/domain/pipeline/` code is not modified beyond passing the new field through.
- No `print` or `debugPrint` in `lib/`; use `AppLogger` via `loggerProvider` if logging is needed. Use `unawaited(...)` for fire-and-forget futures.
- Tests perform no network I/O; widget tests that render `FlutterMap` inject the no-op tile provider the existing tests use. Run the smallest relevant tests first (`flutter test <file>`), then the suites named in each task. The suite has 17 known failures at the start (13 unit: drift integrity, resort attribution, debug export; 4 widget: profile and history screens); do not fix unrelated failures and do not add to them.
- Quality gates for touched files: `dart format --set-exit-if-changed lib test` (run `dart format` on touched files only; the tree is fully formatted), `flutter analyze` with no new issues in touched files (261 older infos exist), `flutter test`.
- Contract discipline: `pressure_hpa` on the point upload and the summary fields on session parsing must match the shared fixtures in `mobile/test/fixtures/contracts/` (copied from the backend by plan 2). If they are missing, stop and report NEEDS_CONTEXT.
- End every commit message with a blank line and then `Claude-Session: https://claude.ai/code/session_019X8gVKYhkwgWtUPFHdpuDd`.

## File Structure

| File | Responsibility |
|---|---|
| `mobile/android/app/src/main/kotlin/com/fallline/mobile/AndroidFusedLocationBridge.kt` | pressure sensor listener; `pressureHpa` in the fix payload |
| `mobile/lib/features/session/domain/location_tracking_repository.dart` | `LocationSample.pressureHpa` |
| `mobile/lib/features/session/data/native_android_tracking_repository.dart` | parse `pressureHpa` from the native payload |
| `mobile/lib/features/session/domain/session_models.dart` | `SessionPointBase.pressureHpa`, `LocalSessionPoint.pressureHpa`, `LocalRideSession.breakCount/breakDurationS` |
| `mobile/lib/core/storage/drift_local_database.dart` | schema version 5: `pressure_hpa`, `break_count`, `break_duration_s` |
| `mobile/lib/core/storage/dao/session_point_dao.dart`, `session_dao.dart`, `remote_session_cache_dao.dart` | read and write the new columns |
| `mobile/lib/features/session/domain/tracking_pipeline.dart`, `session_segmentation.dart`, `recording_controller.dart` (only where a point is constructed) | pass `pressureHpa` through |
| `mobile/lib/features/session/data/session_repository_impl.dart` | `pressure_hpa` in the upload body; real summary fields and break fields from the API |
| `mobile/lib/features/session/presentation/session_detail_screen.dart` | "Breaks" stat |
| tests: `test/unit/native_android_tracking_repository_test.dart`, `test/unit/drift_local_database_integrity_test.dart`, `test/unit/session_repository_impl_test.dart`, `test/unit/contract_fixtures_test.dart` (new), `test/widget/session_detail_screen_test.dart` | |

---

### Task 1: Pressure from the native bridge to `LocationSample`

**Files:**
- Modify: `mobile/android/app/src/main/kotlin/com/fallline/mobile/AndroidFusedLocationBridge.kt` (fields, `beginLocationRequest`, `stopLocationUpdates`, `Location.toPayload`), `mobile/lib/features/session/domain/location_tracking_repository.dart` (`LocationSample`), `mobile/lib/features/session/data/native_android_tracking_repository.dart` (payload parsing near line 252)
- Test: `mobile/test/unit/native_android_tracking_repository_test.dart`

**Interfaces:**
- Produces: native payload key `pressureHpa` (Double or null); `LocationSample.pressureHpa: double?` (constructor parameter `this.pressureHpa`, optional).

- [ ] **Step 1: Write the failing Dart test**

Read `test/unit/native_android_tracking_repository_test.dart` first; it already builds fake native payloads and decodes them into `LocationSample`s. Add, next to the existing payload-parsing test, using that file's helper for emitting a sample map:

```dart
  test('parses pressureHpa from the native payload and tolerates its absence', () async {
    // Build two payloads the way the existing tests do: identical fixes,
    // one with 'pressureHpa': 898.7 and one without the key.
    // Decode both through the repository under test and assert:
    //   withPressure.pressureHpa == closeTo(898.7, 1e-9)
    //   withoutPressure.pressureHpa == null
  });
```
Replace the comment body with the file's real helper calls (the helper names differ per file; keep the assertions exactly).

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/unit/native_android_tracking_repository_test.dart`
Expected: compile error, `pressureHpa` is not a getter of `LocationSample`.

- [ ] **Step 3: Dart model and parser**

In `location_tracking_repository.dart`, add `this.pressureHpa,` to the `LocationSample` constructor (after `speedAccuracyMps` or the last optional parameter) and the field:

```dart
  /// Barometric pressure in hectopascals from the device sensor, or null when
  /// the device has no barometer or the reading was older than 5 s.
  final double? pressureHpa;
```

In `native_android_tracking_repository.dart`, where the payload map becomes a `LocationSample` (the block around line 252 that reads `raw['speedAccuracyMps']`), add:

```dart
        pressureHpa: _asNullableDouble(raw['pressureHpa']),
```

- [ ] **Step 4: Kotlin sensor listener**

Add imports:

```kotlin
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
```

Add fields in `AndroidFusedLocationBridge` next to the other private state:

```kotlin
    private val sensorManager: SensorManager? =
        activity.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val pressureSensor: Sensor? = sensorManager?.getDefaultSensor(Sensor.TYPE_PRESSURE)
    @Volatile private var latestPressureHpa: Float? = null
    @Volatile private var latestPressureAtMs: Long = 0L
    private var pressureListenerRegistered = false
    private val pressureListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            latestPressureHpa = event.values[0]
            latestPressureAtMs = SystemClock.elapsedRealtime()
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    private fun startPressureUpdates() {
        val manager = sensorManager ?: return
        val sensor = pressureSensor ?: return
        if (pressureListenerRegistered) return
        pressureListenerRegistered =
            manager.registerListener(pressureListener, sensor, SensorManager.SENSOR_DELAY_NORMAL)
    }

    private fun stopPressureUpdates() {
        if (!pressureListenerRegistered) return
        sensorManager?.unregisterListener(pressureListener)
        pressureListenerRegistered = false
        latestPressureHpa = null
    }

    private fun currentPressureHpa(): Double? {
        val value = latestPressureHpa ?: return null
        val ageMs = SystemClock.elapsedRealtime() - latestPressureAtMs
        return if (ageMs <= PRESSURE_MAX_AGE_MS) value.toDouble() else null
    }
```

Add `private const val PRESSURE_MAX_AGE_MS = 5_000L` to the companion object that holds `CONTROL_CHANNEL_NAME`. Call `startPressureUpdates()` at the start of `beginLocationRequest(...)` (before `fusedLocationClient.requestLocationUpdates`) and `stopPressureUpdates()` at the end of `stopLocationUpdates(...)`. In `Location.toPayload()`, add `"pressureHpa" to currentPressureHpa(),` after `"isMocked"`. If the activity reference in the class is not named `activity`, use the field the class already uses for `getSystemService`.

- [ ] **Step 5: Verify**

Run: `flutter test test/unit/native_android_tracking_repository_test.dart` (expected: pass). Then `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:8000/v1` from `mobile/` to prove the Kotlin compiles (about 2 to 4 minutes; if the Android SDK is unavailable, say so in the report and do not guess). If a device or emulator with a barometer is attached, run the app, start a recording, and confirm with `adb logcat -s FallLine` (or the tag the bridge already uses) that fixes carry a pressure value; report either way.

- [ ] **Step 6: Gates and commit**

```bash
dart format lib/features/session/domain/location_tracking_repository.dart lib/features/session/data/native_android_tracking_repository.dart test/unit/native_android_tracking_repository_test.dart
flutter analyze
git add android/app/src/main/kotlin/com/fallline/mobile/AndroidFusedLocationBridge.kt lib/features/session/domain/location_tracking_repository.dart lib/features/session/data/native_android_tracking_repository.dart test/unit/native_android_tracking_repository_test.dart
git commit -m "feat(mobile): sample barometric pressure with each native fix"
```

---

### Task 2: Pressure through storage and upload

**Files:**
- Modify: `mobile/lib/features/session/domain/session_models.dart` (`SessionPointBase`, `LocalSessionPoint`, and the second point class around line 254 if it mirrors the fields), `mobile/lib/core/storage/drift_local_database.dart` (schema version 5, `_migrateToV5`), `mobile/lib/core/storage/dao/session_point_dao.dart` (both insert statements and the row mapper), the point construction sites (`grep -n "LocalSessionPoint(" lib` and `grep -n "speedAccuracyMps:" lib/features/session` list them: `tracking_pipeline.dart`, `session_segmentation.dart`, `recording_controller.dart`, `gps_warmup_service.dart`, `geolocator_tracking_repository.dart`), `mobile/lib/features/session/data/session_repository_impl.dart` (upload body near line 785)
- Test: `mobile/test/unit/drift_local_database_integrity_test.dart`, `mobile/test/unit/session_repository_impl_test.dart`, `mobile/test/unit/contract_fixtures_test.dart` (new)

**Interfaces:**
- Produces: `SessionPointBase.pressureHpa: double?` abstract getter, `LocalSessionPoint.pressureHpa` (constructor `this.pressureHpa`), column `local_session_points.pressure_hpa REAL`, upload key `pressure_hpa`.

- [ ] **Step 1: Write the failing tests**

Contract fixture test (new file):

```dart
// test/unit/contract_fixtures_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _load(String name) {
  final file = File('test/fixtures/contracts/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  test('point batch contract fixture carries pressure_hpa on the first point', () {
    final points = _load('session_point_batch.json')['points'] as List<dynamic>;
    expect((points[0] as Map<String, dynamic>)['pressure_hpa'], closeTo(898.7, 1e-9));
    expect((points[1] as Map<String, dynamic>).containsKey('pressure_hpa'), isFalse);
  });

  test('session detail contract fixture carries the summary fields the app maps', () {
    final session = _load('session_detail.json')['session'] as Map<String, dynamic>;
    for (final key in <String>[
      'descent_duration_s', 'descent_distance_m', 'avg_descent_speed_mps',
      'descent_vertical_m', 'lift_vertical_m', 'break_count', 'break_duration_s', 'max_speed_mps',
    ]) {
      expect(session.containsKey(key), isTrue, reason: key);
    }
    expect(session['break_count'], 1);
    expect(session['break_duration_s'], 240.0);
  });
}
```

Drift integrity test, appended to `test/unit/drift_local_database_integrity_test.dart` following its existing open-and-inspect pattern (the file already lists columns with `PRAGMA table_info`; copy that helper usage):

```dart
  test('schema version 5 adds pressure_hpa to local_session_points and break stats to local_ride_sessions', () async {
    // open an in-memory DriftLocalDatabase the way the neighbouring tests do, call initialize()
    // then assert:
    //   columns of local_session_points contain 'pressure_hpa'
    //   columns of local_ride_sessions contain 'break_count' and 'break_duration_s'
    //   PRAGMA user_version == 5
  });
```
Write the body with the file's real helpers; keep the four assertions.

Upload test, appended to `test/unit/session_repository_impl_test.dart` next to the existing test that inspects the points batch body (search for `'speed_accuracy_mps'` in the test file to find it), asserting that a stored point with `pressureHpa: 898.7` uploads `'pressure_hpa': 898.7`, and one with `pressureHpa: 42.0` (out of the physical range) uploads no `pressure_hpa` key (sanitised away, matching the backend's 300 to 1100 bound).

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/unit/contract_fixtures_test.dart test/unit/drift_local_database_integrity_test.dart test/unit/session_repository_impl_test.dart`
Expected: the contract test passes already if plan 2 copied the fixtures (fine); the other two fail (missing column / missing key or compile error).

- [ ] **Step 3: Models**

`SessionPointBase`: add `double? get pressureHpa;` after `String? get motionState;`. `LocalSessionPoint` and any sibling point class that lists the same optional fields: add `this.pressureHpa,` to the constructor and `final double? pressureHpa;` to the fields. Every construction site listed above passes `pressureHpa: sample.pressureHpa` (or `point.pressureHpa`) where a `LocationSample` or point is converted; sites that build points from other sources pass nothing (null).

- [ ] **Step 4: Drift schema and DAO**

`drift_local_database.dart`: `schemaVersion => 5`; add after `_migrateToV3();` in `initialize()`:

```dart
    await _migrateToV5();
```
and the method next to `_migrateToV3`:

```dart
  Future<void> _migrateToV5() async {
    await _addColumnIfMissing('local_session_points', 'pressure_hpa REAL');
    await _addColumnIfMissing(
        'local_ride_sessions', 'break_count INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(
        'local_ride_sessions', 'break_duration_s INTEGER NOT NULL DEFAULT 0');
  }
```
Also add `pressure_hpa REAL,` to the `CREATE TABLE IF NOT EXISTS local_session_points` statement (after `motion_state TEXT`) and `break_count INTEGER NOT NULL DEFAULT 0, break_duration_s INTEGER NOT NULL DEFAULT 0,` to `local_ride_sessions` (after `elevation_loss_m INTEGER`), so fresh installs get the columns without the migration. There is no version 4 to 5 data transform.

`session_point_dao.dart`: add `pressure_hpa` to both column lists and `Variable<double>(point.pressureHpa)` to both variable lists at the matching position; in the row mapper add `pressureHpa: h.asNullableDouble(data['pressure_hpa']),`.

- [ ] **Step 5: Upload**

In `session_repository_impl.dart`, in the point upload map after `'bearing_accuracy_deg'`:

```dart
      'pressure_hpa': _sanitizePressureForSync(
        point.pressureHpa,
        sanitizedFields: sanitizedFields,
      ),
```
and the helper next to `_sanitizeNullableNonNegativeDoubleForSync`:

```dart
  double? _sanitizePressureForSync(
    double? value, {
    required Set<String> sanitizedFields,
  }) {
    if (value == null) return null;
    if (!value.isFinite || value < 300 || value > 1100) {
      sanitizedFields.add('pressure_hpa');
      return null;
    }
    return value;
  }
```
If the map builder drops null values before sending (check how `speed_accuracy_mps: null` is treated in the existing upload test), the out-of-range case yields no key, which is what the test asserts; otherwise assert `isNull` instead and say so in the report.

- [ ] **Step 6: Run, gates, commit**

Run: `flutter test test/unit/contract_fixtures_test.dart test/unit/drift_local_database_integrity_test.dart test/unit/session_repository_impl_test.dart test/unit/session_point_dao_test.dart` (the last only if it exists), then `flutter test test/unit`. Expected: no new failures against the 13 known unit failures.

```bash
dart format <touched lib and test files>
flutter analyze
git add <touched paths>
git commit -m "feat(mobile): store and upload barometric pressure with session points"
```

---

### Task 3: Real summary fields and break stats from the API

**Files:**
- Modify: `mobile/lib/features/session/domain/session_models.dart` (`LocalRideSession`), `mobile/lib/core/storage/dao/session_dao.dart` (row mapper; every INSERT or UPDATE that writes the stats columns), `mobile/lib/core/storage/dao/remote_session_cache_dao.dart` (upsert columns), `mobile/lib/features/session/data/session_repository_impl.dart` (the two remote-session parsers around lines 1250 and 1700)
- Test: `mobile/test/unit/session_repository_impl_test.dart`

**Interfaces:**
- Produces: `LocalRideSession.breakCount: int` and `breakDurationS: int` (constructor parameters `this.breakCount = 0`, `this.breakDurationS = 0`, optional so existing call sites compile); remote parsing reads `descent_duration_s`, `descent_distance_m`, `avg_descent_speed_mps`, `lift_vertical_m`, `descent_vertical_m`, `break_count`, `break_duration_s`.

- [ ] **Step 1: Write the failing test**

In `test/unit/session_repository_impl_test.dart`, next to the tests that parse remote sessions (search for `elevation_gain_m` or `_remote` in the test file), add a test that feeds the parser the `session` object from `test/fixtures/contracts/session_detail.json` (read with `dart:io` and `jsonDecode`) and asserts on the resulting `LocalRideSession`:

```dart
    expect(session.activeDurationS, (fixture['descent_duration_s'] as num).round());
    expect(session.distanceM, closeTo((fixture['descent_distance_m'] as num).toDouble(), 1e-6));
    expect(session.avgSpeedMps, closeTo((fixture['avg_descent_speed_mps'] as num).toDouble(), 1e-6));
    expect(session.maxSpeedMps, closeTo((fixture['max_speed_mps'] as num).toDouble(), 1e-6));
    expect(session.elevationGainM, (fixture['lift_vertical_m'] as num).round());
    expect(session.elevationLossM, (fixture['descent_vertical_m'] as num).round());
    expect(session.breakCount, 1);
    expect(session.breakDurationS, 240);
```
Use whichever public path the existing tests use to exercise remote parsing (a fetched detail or a history page); if both parsers are reachable, test both.

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/unit/session_repository_impl_test.dart`
Expected: compile error on `breakCount`, or zeros for the stats.

- [ ] **Step 3: Model, DAOs, parsers**

`LocalRideSession`: add `this.breakCount = 0,` and `this.breakDurationS = 0,` to the constructor and `final int breakCount; final int breakDurationS;` fields. `session_dao.dart` `_mapSession`: add `breakCount: h.asInt(data['break_count'] ?? 0), breakDurationS: h.asInt(data['break_duration_s'] ?? 0),`. Every DAO statement that writes remote stats into `local_ride_sessions` or the remote cache (`remote_session_cache_dao.dart` upsert; the `session_dao.dart` path that stores a fetched remote session; `completeLocalSession` writes local stats and leaves the break columns at their defaults) gains the two columns and variables.

In both remote parsers in `session_repository_impl.dart` replace the five stat lines with:

```dart
      activeDurationS: _remoteIntOrZero(raw['descent_duration_s']),
      distanceM: _remoteDoubleOrZero(raw['descent_distance_m']),
      maxSpeedMps: _remoteDoubleOrZero(raw['max_speed_mps']),
      avgSpeedMps: _remoteDoubleOrZero(raw['avg_descent_speed_mps']),
      elevationGainM: _remoteNullableInt(raw['lift_vertical_m']),
      elevationLossM: _remoteNullableInt(raw['descent_vertical_m']),
      breakCount: _remoteIntOrZero(raw['break_count']),
      breakDurationS: _remoteIntOrZero(raw['break_duration_s']),
```
`_remoteIntOrZero` and `_remoteNullableInt` must round a decimal JSON number rather than throw (check their bodies; `descent_vertical_m` arrives as a decimal).

- [ ] **Step 4: Run, gates, commit**

Run: `flutter test test/unit/session_repository_impl_test.dart test/unit/drift_local_database_integrity_test.dart`, then `flutter test test/unit` (no new failures).

```bash
dart format <touched files>
flutter analyze
git add <touched paths>
git commit -m "fix(mobile): map the backend session summary fields and break stats"
```

---

### Task 4: "Breaks" on the session detail screen

**Files:**
- Modify: `mobile/lib/features/session/presentation/session_detail_screen.dart` (the `Wrap` of `StatBlock`s after the `Runs` block)
- Test: `mobile/test/widget/session_detail_screen_test.dart`

- [ ] **Step 1: Write the failing widget test**

Read the existing detail-screen widget test; it builds a `SessionDetail` with a session and stats and injects the no-op tile provider. Add a test that builds a session with `breakCount: 2, breakDurationS: 1500` and expects `find.text('Breaks')` and `find.text('2 · 25m')` to be present; and one with `breakCount: 0` expecting `find.text('0')` under the `Breaks` label (the label is always shown).

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/widget/session_detail_screen_test.dart`
Expected: `Breaks` not found.

- [ ] **Step 3: Implement**

After the `Runs` `StatBlock` add:

```dart
                            StatBlock(
                                value: _formatBreaks(
                                    session.breakCount, session.breakDurationS),
                                label: 'Breaks',
                                size: StatSize.small),
```
and a private top-level helper in the same file:

```dart
String _formatBreaks(int count, int durationS) {
  if (count == 0) return '0';
  final minutes = (durationS / 60).round();
  return '$count · ${minutes}m';
}
```

- [ ] **Step 4: Run, gates, commit**

Run: `flutter test test/widget/session_detail_screen_test.dart`, then `flutter test` (whole suite; no new failures against the 17 known).

```bash
dart format lib/features/session/presentation/session_detail_screen.dart test/widget/session_detail_screen_test.dart
flutter analyze
git add lib/features/session/presentation/session_detail_screen.dart test/widget/session_detail_screen_test.dart
git commit -m "feat(mobile): show break count and time on the session detail screen"
```

---

### Task 5: Mobile quality gates

**Files:** none new.

- [ ] **Step 1:** `dart format --set-exit-if-changed lib test` (expected exit 0; if not, format only the files this plan touched and commit them as `style(mobile): dart format after GPS segmentation`).
- [ ] **Step 2:** `flutter analyze` (no new issues in touched files; report the total against 261).
- [ ] **Step 3:** `flutter test` (report the failure list against the 17 known; the new tests from Tasks 1 to 4 must pass).
- [ ] **Step 4:** If a device with a barometer is available: install a debug build, record a short session outdoors, sync it, and confirm in the backend database that `session_points.pressure_hpa` is populated and that the detail screen shows non-zero descent stats after the backend analysis. Report the result or that no device was available.
