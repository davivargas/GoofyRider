# Fall Line rename — what is left before release

The rename from GoofyRider to Fall Line landed in one commit on this branch
(`refactor: rename GoofyRider to Fall Line`). Everything a user reads was
renamed, and so was every identifier that could be changed without throwing
away data that already exists.

This document lists what was **deliberately left named `goofyrider`**, why,
and what each one costs to finish. Work through it before the app goes out
for real usage or a public demo.

## The one decision that makes this easy or hard

Every remaining item is a **key that points at stored data**. Renaming a key
does not move the data behind it — it points the app at a new, empty place.

So the cost depends entirely on one question:

> Does any install exist whose data must survive?

- **No (dev devices only, data you can recreate)** — then this whole document
  collapses into a find-and-replace plus a one-time reset. Do it now. This is
  the cheapest it will ever be, and the window closes the moment you hand the
  app to someone else.
- **Yes (a tester's phone, a demo device, your own season of rides)** — then
  each item below needs a migration, or a deliberate decision to accept the
  reset.

If you are unsure, assume "yes" for the Drift database. Unsynced rides live
only on the device, and there is no server copy to restore them from.

---

## 1. Mobile — keys that point at on-device data

### 1.1 Secure-storage token keys

`mobile/lib/core/storage/token_storage.dart:38-42`

```dart
static const String _accessKey      = 'goofyrider_access_token';
static const String _refreshKey     = 'goofyrider_refresh_token';
static const String _userIdKey      = 'goofyrider_user_id';
static const String _emailKey       = 'goofyrider_user_email';
static const String _displayNameKey = 'goofyrider_user_display_name';
```

**If renamed with no migration:** every signed-in user is silently logged out
on next launch. The app looks broken rather than updated, because the tokens
are still on the device under the old names — just unreachable.

**Migration:** on first launch after the upgrade, read each old key, write the
value to the new key, delete the old key. Keep that code for at least one
release, then delete it. Roughly twenty lines in `SecureTokenStorage`, plus a
unit test that seeds old keys and asserts the new ones are populated and the
old ones gone.

**Recommendation:** leave these alone permanently. They are private to the
app, no user ever sees them, and the only thing a rename buys is tidiness in a
file nobody reads. Tidiness is not worth a logout path.

### 1.2 Drift database filename

`mobile/lib/core/storage/drift_local_database.dart:53`

```dart
static const String _dbFileName = 'goofyrider_local.sqlite';
```

**If renamed with no migration:** the app opens a brand-new empty database.
Every locally recorded session that has not synced is gone, along with cached
resorts and weather. This is the most destructive item in the list.

**Migration:** before opening the database, check whether the old file exists
and the new one does not; if so, rename the file on disk, then open. Must also
move the `-wal` and `-shm` sidecar files if present. Needs a test that seeds a
legacy file and asserts the rows survive — the existing
`drift_local_database_integrity_test.dart` already has legacy-schema fixtures
to copy the shape from.

**Recommendation:** leave this alone permanently. Same reasoning as the tokens,
with a worse failure mode.

### 1.3 Unit preference keys

`mobile/lib/core/providers/speed_unit_preference_provider.dart:9`
`mobile/lib/core/providers/distance_unit_preference_provider.dart:9`

```dart
const String _speedUnitStorageKey    = 'goofyrider_speed_unit';
const String _distanceUnitStorageKey = 'goofyrider_distance_unit';
```

**If renamed with no migration:** the user's km/h-versus-mph and m-versus-ft
choices silently revert to defaults. Low stakes, mildly annoying, easy to miss
in testing because the defaults look correct.

**Recommendation:** leave alone, or rename together with a migration if you are
already writing one for the tokens.

### 1.4 Debug export filename

`mobile/lib/features/profile/presentation/debug_export_service.dart:137`

The exported file is named `goofyrider_debug_<timestamp>.json`. Nothing reads
it back, so renaming is free — but note the feature is currently commented out
in `profile_screen.dart`, so the filename is not reachable from the UI.

**Recommendation:** rename when you re-enable the export, not before.

### 1.5 Notification channel id (already changed — verify)

`TrackingForegroundService.kt` now uses `fallline_tracking`. On a device that
ran the old build, the old `goofyrider_tracking` channel lingers in Android
settings until reinstall. Harmless, but if you are testing notification
behaviour on a device that had the old build, uninstall first so you are not
reading stale per-channel settings.

---

## 2. Backend and infrastructure

### 2.1 Postgres volume

`docker-compose.yml:13, 55-56` — `goofyrider_postgres_data`

Renaming the volume points Compose at a new empty volume. The old one is not
deleted, but the stack comes up with no data: no users, no imported resorts.

**Migration:** `docker run --rm -v old:/from -v new:/to alpine cp -a /from/. /to/`
then switch the name. Or accept the reset and re-run
`python -m app.scripts.import_resorts`.

**Recommendation:** leave alone. The volume name is invisible outside your
machine and CI.

### 2.2 Database names

`.env` (`POSTGRES_DB`, and the database segment of `DATABASE_URL`) names the
database `goofyrider`; the test database is `goofyrider_test`. CI hardcodes
`goofyrider_test`, `goofyrider_user` and `goofyrider_password` in
`.github/workflows/ci.yml:26-38`.

Renaming means creating the new database and migrating or reimporting. CI is
free to rename because its Postgres service is created fresh per run — but keep
CI and local matching, or the mismatch will confuse whoever debugs a failure.

Note that `app/core/database_safety.py` does **not** hardcode a name: it
requires `test` as a standalone token anywhere in the database name, so any
`*_test` name satisfies the guard. Two unit fixtures in
`tests/unit/test_database_safety.py` and one in `tests/unit/test_config.py`
use `goofyrider` as sample text and would need updating alongside.

**Recommendation:** rename only if you are already recreating the databases for
another reason.

### 2.3 Docker container names (already changed)

Now `fallline_db` and `fallline_backend`. If a container from the old names is
still running it holds port 5432 — run `docker compose down` before the next
`docker compose up -d`. The volume is unaffected either way.

---

## 3. Repository and tooling

### 3.1 Repository folder name

The git repository root is still `goofyrider/`. Renaming it breaks every
absolute path in local tooling, IDE project files, and the `.claude/` settings
allowlists, and it rewrites nothing inside the repo. The folder name is not
visible to users.

**Recommendation:** rename only when convenient, e.g. at your next fresh clone.
Note that `CLAUDE.md` and the root `README.md` reference `goofyrider/` paths and
would need updating together.

### 3.2 IDE module files

`mobile/.idea/modules.xml` still points at `goofyrider_mobile.iml`. These are
gitignored and regenerated by the IDE. Delete `mobile/.idea/` and reopen the
project if the module name bothers you.

### 3.3 Test-local temp directory prefixes

`drift_local_database_integrity_test.dart` creates temp directories prefixed
`goofyrider_legacy_db_`. Cosmetic, test-only, zero risk either way.

---

## 4. Before the store listing

### 4.1 Confirm the application id

Currently `com.fallline.mobile` (`mobile/android/app/build.gradle.kts:9,24`).
This was chosen to clear the `com.example` prefix, which the Play Store rejects
outright. An application id is never verified against DNS, so it claims no
domain — but it is **permanent once published**. Decide now whether you want
`com.fallline.mobile`, a `.app` variant, or a personal namespace, because after
the first release the only way to change it is to ship a second, separate app.

### 4.2 Branding artwork

`mobile/assets/branding/` holds `icon.png`, `splash.png` and
`splash_center_icon.png`. These are images: if the GoofyRider wordmark is drawn
into any of them, a rename does not touch it. Open each one and check. The
launcher icon and splash are the two things a user sees before any of the
renamed strings load.

### 4.3 Verify the visible name end to end

Install a release build and confirm the name in: the launcher label, the splash
screen, the login and home wordmark, the recording notification, the Android
app-info screen, and the permission-denied hints (which tell the user to find
the app by name in Settings, so they must match the launcher label exactly).

The wordmark itself is a build-time constant —
`AppConstants.brandWordmark`, overridable with
`--dart-define=BRAND_WORDMARK="..."` — so confirm the release build is not
passing an override that contradicts the launcher label.

---

## 5. Other known pre-release items (not rename-related)

Carried over from the redesign review, recorded here so the launch checklist is
in one place:

- **Four failing tests predate this work** and are not regressions: three
  `profile_screen_test.dart` export tests and one `history_screen_test.dart`
  sync-tooltip assertion. All four target features that are currently commented
  out in the app. Either re-enable the features or delete the tests — leaving
  known-red tests in the suite trains everyone to ignore failures.
- **Thirteen unit tests require native sqlite** and fail in a bare environment.
  Worth documenting as an environment prerequisite so a new machine does not
  read them as breakage.
- **Large system font sizes** may overflow the fixed-aspect stat grids on the
  record screen. Test with Android's font size set to Largest.
- **The auto-pause banner overlaps the speed hero** on the record screen's map
  layout.
- **Bundled fonts add roughly 1.9 MB** to the APK. Subsetting Archivo and
  JetBrains Mono to the glyphs actually used would recover most of it.

---

## Suggested order

1. Decide the application id (4.1) — it is the only irreversible one.
2. Check the branding artwork (4.2).
3. Decide whether any install's data must survive. If not, reset dev data and
   rename everything in section 1 in one pass.
4. Leave sections 2 and 3 alone unless you are already recreating the
   databases or cloning fresh.
5. Clear the four red tests (5) so the suite means something.
6. Verify the visible name on a release build (4.3).
