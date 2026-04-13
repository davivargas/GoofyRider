# GoofyRider

GoofyRider is an Android-first, offline-first snowboarding tracker built for portfolio-quality engineering.
It includes a Flutter mobile app and a FastAPI backend with PostgreSQL.

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
