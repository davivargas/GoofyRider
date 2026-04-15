# GoofyRider

GoofyRider is an Android-first, offline-first snowboarding tracker built for portfolio-quality engineering.
It includes a Flutter mobile app and a FastAPI backend with PostgreSQL.

## Quickstart for reviewers

This project bundles a pre-populated `goofyrider/.env` and
`goofyrider/mobile/mapbox.json` so no keys need to be obtained.
Follow the steps in order on a single machine.

### 1. Install prerequisites

- **Docker Desktop** (Windows / macOS) or `docker` + `docker compose` (Linux).
  Start Docker Desktop and confirm `docker compose version` prints a version.
- **Flutter SDK ≥ 3.4.0** (Dart SDK comes bundled). Verify with
  `flutter --version`, then run `flutter doctor` and resolve anything it
  flags as blocking for the Android toolchain.
- **Android Studio** with the **Android SDK**, **Android SDK Platform-Tools**,
  and **Android Emulator** components installed (installed by default with
  Android Studio). Accept Android licenses once with
  `flutter doctor --android-licenses`.
- **Android Virtual Device (AVD)**: in Android Studio, open
  *Device Manager → Create Device* and create an emulator (a Pixel image
  with Google Play, API 33+ is fine). Boot it once to confirm it works.
  Alternatively, connect a physical Android device with USB debugging
  enabled — but the default `API_BASE_URL` below assumes an emulator.

### 2. Start the backend

From the `goofyrider/` directory:

```bash
docker compose up --build -d
```

This builds the backend image, starts PostgreSQL, runs Alembic migrations,
and imports the resort catalog from SkiAPI on first boot. The first start
can take 1–2 minutes while the resort import finishes — tail the logs to
watch progress:

```bash
docker compose logs -f backend
```

When you see `Uvicorn running on http://0.0.0.0:8000`, open
<http://127.0.0.1:8000/docs> in a browser. If the interactive API docs
load, the backend is healthy.

### 3. Run the mobile app

In a second terminal, still from `goofyrider/`:

```bash
cd mobile
flutter pub get
```

Make sure the Android emulator from step 1 is booted (open Android
Studio → Device Manager → hit the play arrow, or run
`flutter emulators --launch <emulator_id>`). Then:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000/v1 --dart-define-from-file=mapbox.json
```

- `10.0.2.2` is the special address Android emulators use to reach the
  host machine's `localhost`, which is where the backend is now listening.
- `--dart-define-from-file=mapbox.json` passes the pre-populated Mapbox
  tile credentials. Omit it and map tiles fall back to OpenStreetMap.
- The first build can take several minutes while Gradle downloads the
  Android build tooling.

Once the app is on the emulator:

1. Register a new account on the login screen.
2. On the Resorts tab, pick a resort and add it to favorites — this
  confirms the backend resort catalog imported correctly.
3. On the Record tab, grant location permission when prompted and start
  a recording. On an emulator you can simulate GPS motion through
  *Extended Controls → Location → Routes* in the emulator toolbar.

### Troubleshooting

- **`flutter run` fails with a network error**: make sure the backend is
  still running (`docker compose ps`) and that you are on an emulator —
  `10.0.2.2` only works inside Android emulators. On a physical device,
  substitute your host's LAN IP for `10.0.2.2`.
- **Resort list is empty**: the initial SkiAPI import may still be
  running. Re-check `docker compose logs -f backend` for
  `Resort import complete`. Pull-to-refresh the Resorts tab once it
  finishes.
- **Map tiles are blank or show a watermark**: the `--dart-define-from-file`
  flag was not passed, or `mobile/mapbox.json` was edited. Re-check the
  file and re-run.
- **"No devices found"**: the emulator is not booted. Run
  `flutter devices` to confirm a device is listed before `flutter run`.

## What is implemented

### Backend (Phases 1-3 + weather/session extensions)
- JWT auth (`register`, `login`, `refresh`, `logout`, `me`)
- Resorts search/detail
- Favorites add/remove/list
- Session lifecycle:
  - create draft
  - upload points batch (idempotent by `t_offset_ms`)
  - complete session
  - get session detail
  - get session points
  - list user sessions (with resort summary)
- Weather endpoint via Open-Meteo proxy + 60-minute cache:
  - `GET /v1/weather/resorts/{resort_id}`

### Mobile (Phases 4-10 implementation baseline)
- Riverpod app bootstrap
- go_router shell with 5 tabs:
  - Home
  - Resorts
  - Record
  - History
  - Profile
- Auth flow with secure token storage and Dio refresh interceptor
- Resorts list/search/detail + favorite toggle
- Local-first recording flow:
  - permission handling
  - geolocator stream
  - Android foreground notification config
  - local session + point persistence (Drift-backed custom SQL store)
  - point filtering + stats engine (Haversine, speed filters, elevation smoothing)
- Sync flow:
  - create draft
  - batch upload accepted points
  - complete session
  - local sync state transitions
- History and session detail with route replay
- Weather cards from backend weather endpoint
- Profile settings placeholders and cache clear

## Tech stack

### Mobile
- Flutter
- Riverpod
- go_router
- Dio
- Drift
- geolocator
- flutter_map

### Backend
- FastAPI
- SQLAlchemy 2.x
- Alembic
- PostgreSQL
- Pydantic v2

## Project structure

```text
goofyrider/
  backend/
    Dockerfile
    .dockerignore
    app/
      api/
      core/
      models/
      repositories/
      schemas/
      services/
    alembic/
    tests/
  mobile/
    lib/
      app/
      core/
      features/
    test/
    integration_test/
  .github/workflows/ci.yml
```

## Local setup

### 1. Start PostgreSQL

From repo root:

```bash
docker compose up -d
```

### 2. Backend

Containerized (recommended for parity):

```bash
docker compose up --build backend
```

Before first run, set `SKI_API_KEY` (and optionally `SKI_API_HOST`) in `.env`.

This starts:
- `db` (PostgreSQL)
- `backend` (FastAPI + Alembic migration + SkiAPI resort import on startup + weekly resort sync)

Optional sync controls:
- `RESORT_SYNC_ENABLED` (default: `true`)
- `RESORT_SYNC_INTERVAL_DAYS` (default: `7`)

API docs:
- `http://127.0.0.1:8000/docs`

Local Python workflow (optional):

```bash
cd backend
python -m venv .venv
# Windows
.venv\Scripts\activate
# macOS/Linux
source .venv/bin/activate

pip install -e .[dev]
alembic upgrade head
python -m app.scripts.import_resorts
uvicorn app.main:app --reload
```

### 3. Mobile

```bash
cd mobile
flutter pub get
```

`API_BASE_URL` is required. Choose one workflow:

- Android emulator:
  - `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000/v1`
- Physical Android device on the same LAN:
  - `flutter run --dart-define=API_BASE_URL=http://<your-lan-ip>:8000/v1`
- Physical Android device via public tunnel:
  - `flutter run -d <device-id> --dart-define=API_BASE_URL=https://<your-tunnel-host>/v1`
- Local development with a custom backend URL:
  - `flutter run --dart-define=API_BASE_URL=http://<host-or-ip>:<port>/v1`

Notes:

- `10.0.2.2` is Android-emulator loopback only.
- If you run on a physical device and use `10.0.2.2`, requests will fail with network errors.

#### Map tile provider

Production map tiles come from Mapbox. Debug builds fall back to
OpenStreetMap direct tiles if no Mapbox defines are passed — that fallback
is intended for local dev and tests only and must not be shipped (OSM's
tile usage policy forbids app distribution against their servers).

Copy `mapbox.json.example` to `mapbox.json` (gitignored) and replace the
placeholder token with your own from
<https://account.mapbox.com/access-tokens/>:

```bash
cp mapbox.json.example mapbox.json
# edit mapbox.json and set MAPBOX_ACCESS_TOKEN
```

Then:

- Debug build with Mapbox (recommended for real testing):
  - `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000/v1 --dart-define-from-file=mapbox.json`
- Debug build without Mapbox (OSM dev fallback):
  - `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000/v1`
- Release build:
  - Both `MAPBOX_STYLE_ID` and `MAPBOX_ACCESS_TOKEN` are **required**. Bootstrap will throw if either is missing. Pass them via `--dart-define-from-file=mapbox.json` locally, or inject from your CI secret store into the Gradle build.

`MAPBOX_STYLE_ID` must include the owner prefix, e.g. `mapbox/outdoors-v12`
or `<your-username>/<your-style-id>` — Mapbox's style tile API rejects
bare style ids. Mapbox public tokens (`pk.*`) are not truly secret; lock
them down in the Mapbox dashboard with your Android package name and SHA-1
fingerprint rather than relying on source-level secrecy.

## Testing

### Backend

Containerized smoke check:

```bash
docker compose up --build -d backend
```

Local Python tests:

```bash
cd backend
.venv\Scripts\python.exe -m pytest
```

`tests/qa` truncates database tables as part of setup/teardown, so point
`DATABASE_URL` at a dedicated test database such as `goofyrider_test`.

### Mobile

```bash
cd mobile
flutter test
```

## CI

GitHub Actions workflow runs:
- backend migrations + backend tests
- flutter analyze + flutter test

File:
- `.github/workflows/ci.yml`

## Screenshots

Add screenshots under `docs/screenshots/` (recommended):
- login
- resorts list/detail
- record screen (recording state)
- history list
- session detail replay

## Known limitations

- Mobile implementation was scaffolded in one pass and should be validated on a real Android device.
- Kotlin native bridge for advanced background tracking is not implemented yet (Flutter geolocator path is active).
- Remote-only session replay points are not persisted locally unless synced into local records.
- UI polish/motion can be refined further after device QA.

## License

Educational and portfolio use.
