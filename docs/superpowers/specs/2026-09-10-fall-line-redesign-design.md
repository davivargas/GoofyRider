# Fall Line Redesign — mobile app visual refactor

Date: 2026-09-10
Source: Claude Design project "Fall Line Redesign.dc.html" + "TabBar.dc.html"
(project 03e4abc3-6b8e-4f00-ad09-479c5a39be43).
Scope: `goofyrider/mobile` presentation layer only. No backend, DAO, pipeline,
state machine or contract changes.

## Goal

Restyle every screen of the Flutter app to the canvas: near-black night-ops
surfaces, one volt accent, mono telemetry labels, dark map that fuses with the
UI, and a matching light mode. One colour language across record, timeline and
history: volt = descent, ice = lift, gray = idle.

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Wordmark | `AppConstants.brandWordmark`, default `GOOFYRIDER`. |
| Record layout | Both canvas versions, MAP / HUD toggle, map-first default. |
| Theme mode | Dark + light tokens, `ThemeMode.system`. |
| Gamification | Skipped (no streak chip, no badges). |
| Onboarding | One location step before the permission prompt, shown once. |
| Fonts | Archivo + JetBrains Mono bundled as assets. |
| Tests | Keep behavioural assertions, rewrite presentational ones. |
| Stale tests | Profile debug-export tests and history "Sync now" tooltip test already fail (code commented out); left untouched, reported. |

## 1. Tokens, theme, fonts

`lib/app/theme/app_theme.dart` is rewritten.

Dark tokens: bg `#0C0F12`, canvas `#07090B`, surface `#14181D`, raised
`#1A1F25`, line `rgba(255,255,255,.07)`, text `#EEF3F6`, textSecondary
`#93A1AD`, textMuted `#5E6B76`, textFaint `#3E4750`, volt `#C6F24E`, voltText
`#C6F24E`, ice `#6BD3FF`, rec `#FF5C5C`, idle `#2A323B`, idleSwatch `#55616C`,
mapBg `#10151A`, mapGlow `#1B2632`, barBg `rgba(10,13,16,.9)`.

Light tokens: bg `#F2F4F1`, surface `#FFFFFF`, raised `#F2F4F1`, line
`rgba(16,22,27,.08)`, text `#10161B`, textSecondary `#5A6873`, textMuted
`#8A96A0`, textFaint `#B8C0BC`, volt `#C6F24E` (fills), voltText `#5E8F0A`
(text/strokes; `#48700B` for small mono text), ice `#1279A8` (`#4FB7E8` for
bars), rec `#D93B3B`, idle `#D5DAD2`, idleSwatch `#B8C0BC`, mapBg `#E8EDEA`,
mapGlow `#FFFFFF`, barBg `rgba(255,255,255,.92)`.

`AppTokens extends ThemeExtension<AppTokens>` carries these semantic colours
plus `descent` (= volt), `lift` (= ice), `idleSegment`. Screens read
`Theme.of(context).extension<AppTokens>()!` (helper `context.tokens`). No
hardcoded `Color(0x...)` in screens after this change.

Typography: `TextTheme` uses Archivo for display/headline/title/body and
JetBrains Mono for label styles. Hero number sizes (68/58/84/148) are set
locally via `StatBlock`, not the text theme.

Material components restyled through the theme: `FilledButton` volt with dark
text, `OutlinedButton` hairline ghost, `InputDecorationTheme` surface fill,
14 radius, mono hint, `SnackBar`, `Dialog`, `BottomSheet`, `Card` (surface,
18 radius, hairline border, zero elevation), `AppBar` transparent.

Fonts: `assets/fonts/Archivo-{Regular,SemiBold,Bold,ExtraBold,ExtraBoldItalic}.ttf`
and `assets/fonts/JetBrainsMono-{Regular,SemiBold,Bold}.ttf`, OFL licensed,
declared in `pubspec.yaml` with the OFL licence files alongside.

`main.dart`: `themeMode: ThemeMode.system` in both `GoofyRiderApp` and
`BootstrapErrorApp`.

`AppConstants.brandWordmark` = `String.fromEnvironment('BRAND_WORDMARK',
defaultValue: 'GOOFYRIDER')`.

## 2. Shared widgets (`lib/core/widgets/`)

| Widget | Purpose |
|---|---|
| `MonoLabel` | Uppercase JetBrains Mono caption with letter spacing and colour variants (secondary / muted / volt / ice). |
| `StatBlock` | Archivo number over a `MonoLabel`; sizes `hero`, `large`, `medium`, `small`. |
| `SurfaceCard` | Surface fill, hairline border, radius 14–18, optional volt border. |
| `StatusPill` | Rounded 20 pill; variants `rec`, `volt`, `ice`, `ghost`. |
| `VoltButton` / `GhostButton` | Full-width mono uppercase actions, radius 14, busy spinner support. |
| `Wordmark` | Brand text in italic 800 Archivo with volt period; size param. |
| `SegmentSwatch` | 8×8 radius-2 square coloured by `SessionActivityType`. |
| `InitialsAvatar` | Circle with initials, optional volt ring. |
| `AppTabBar` | Canvas TabBar: 5 items, record puck, active volt dot, translucent bar. Lives in `lib/app/shell/`. |

`AppEmptyView`, `AppErrorView`, `AppLoadingView` restyled in place (mono
labels, ghost retry button).

## 3. Shell, routing, onboarding

`AppShell` uses `AppTabBar`. Labels: HOME, RESORTS, RECORD, SEASONS, PROFILE.
Branch order unchanged. `Scaffold.extendBody: true` so maps run under the
translucent bar; screens add bottom padding equal to the bar height.

New route `RoutePaths.onboardingLocation = '/onboarding/location'` with
`LocationOnboardingScreen` in `lib/features/session/presentation/onboarding/`.
Gating: `locationOnboardingSeenProvider` (`StateNotifierProvider<..., bool?>`)
loads `GpsWarmupPermissionPreference.hasBeenRequested()` at bootstrap. Router
redirect: authenticated and seen == false and not already on onboarding →
onboarding. ALLOW LOCATION → `ensureForegroundPermission()` then
`markRequested()` and `go(home)`. NOT NOW → `markRequested()` and `go(home)`.
`_ensureGpsWarmupPermissionOnce` is removed from `main.dart`; the warm-up
foreground call after onboarding stays.

## 4. Screens

Common: 24 px horizontal padding, top row is a plain `SafeArea` (no
`AppBar`), section captions are `MonoLabel`s, list rows separated by hairlines.

### Login / Register (1i)
Wordmark 44, tagline `TRACK EVERY LINE.`, fields with mono uppercase labels
(`EMAIL`, `PASSWORD`, register adds `DISPLAY NAME`), `LOG IN` volt,
`CREATE ACCOUNT` ghost (register: `CREATE ACCOUNT` volt, `BACK TO LOG IN`
ghost), footnote "Rides record offline — sign in to sync them." Validation
messages, busy spinner, error text unchanged.

### Home (1a)
Header: `Wordmark` 16 + `InitialsAvatar`. Season block: caption
`SEASON yy/yy · N DAYS RIDDEN` (season via `seasonLabelForDate(now)`, days =
distinct local ride dates), hero total vert (sum `elevationLossM` over the
season, formatted by distance unit, `--` when none), then `TOP <unit>`,
`<unit> DIST`, `SESSIONS`, `RIDE TIME`. Last-session card: `LAST SESSION ·
MMM D`, resort label, `hh:mm RIDE · dist · max`, sync `StatusPill`
(`● SYNCED` ice / `○ LOCAL ONLY` muted). `YOUR MOUNTAINS` caption + two-up
favourite cards: name, `temp · CONDITIONS`, snow chip (`N CM · 24H`, volt fill
when ≥ 10 cm) only when live weather has `snowfallCm24h`. Empty states keep
their current copy. Pull-to-refresh and debug unsynced banner unchanged. Tap
targets unchanged (session → detail, resort → detail).

### Record (1b + 1c)
Top row: `StatusPill.rec` showing `● REC hh:mm:ss` while recording/paused,
`READY` ghost otherwise; phase pill (`RECORDING` volt, `PAUSED`, `AUTO-PAUSED`,
`READY`); GPS pill with bars (existing `_GpsSignalBars`, semantics label
kept); `MAP | HUD` toggle. Local `bool _hudMode` (default false).

Map-first: `FlutterMap` fills the body (under the tab bar), existing follow,
recenter, warm-up marker, tile-error handling. Route polyline volt, rider
marker volt dot with halo. Speed overlay bottom-left above the sheet
(`StatBlock.hero` 84 + `<unit>`). Bottom sheet: 3×2 grid `MAX`, `VERT`,
`DIST`, `ALT`, `RIDE AVG`, `RIDE TIME`, then `PAUSE`/`RESUME` ghost and
`FINISH`/`START RECORDING` volt. Vertical and altitude formatting unchanged.

HUD-first: caption `<phase> · <resort or SESSION>`, 148 pt speed with muted
decimals, `<unit>` caption, `SESSION MAX <value>` with proportional bar,
four `SurfaceCard` tiles (`VERT`, `DIST`, `RIDE TIME`, `ALT`), 96 px route
thumbnail (`FlutterMap` with interactions disabled, same tile config,
`TAP FOR MAP ↗` switches to map mode), same control row.

Auto-pause banner (restyled surface strip), recovery bottom sheet, permission
snackbars, permission/GPS-off banners unchanged in behaviour.

### Session detail (1d)
Header: back chevron, resort label + `MMM D, YYYY · h:mm A`, sync pill,
`⋮` `PopupMenuButton` (tooltip `Session actions`, `Delete session`). Hero:
vert (`elevationLossM`) + `MAX`, `DIST`, `RUNS` (count of descent segments).
`TIME SPLIT · total` with legend and a three-part bar (descent/lift/idle
proportions; single ride bar when no timeline). Map card 210 px, descents
volt, lifts ice, idle muted, start dot text colour, end dot volt. `TIMELINE`
rows: swatch, type, `h:mm–h:mm`, `mm:ss · dist`. Fallback copy when the
timeline is empty stays. `SYNC NOW` / `RETRY SYNC` volt button when unsynced.
Debug diagnostics and route metadata cards restyled, debug-only.

### Seasons (1e)
Title `SEASONS`, header sync icon when unsynced > 0. Season header:
outlined-volt `yy/yy` numerals (stroke `Paint` foreground) +
`N DAYS · vert · top`. Session card: date box (`D` / `MMM`), divider, resort,
`mm:ss · dist · max`, sync label (`● SYNCED` ice, `○ LOCAL ONLY`, `◌ SYNCING`,
`! FAILED` rec). Empty and error states unchanged.

### Resorts (1f)
Title `RESORTS`, search field (mono hint `Search resorts…`), caption
`FAVORITES FIRST` when any favourite, rows: name, `REGION, COUNTRY`, weather
chip (`temp · CONDITIONS` from cached weather) and heart icon button (volt
filled when favourite, muted outline otherwise). Debounced search, favourite
toggle, refresh, empty/error states unchanged.

### Resort detail (1g)
Map hero 400 px (clamped to 45 % of height) with bottom gradient fade,
floating circular back and heart buttons (tooltips `Add favorite` /
`Remove favorite`). Name in italic 800 40 pt uppercase, `REGION, COUNTRY`
caption (city appended when present). Tiles: temp + conditions, `SNOW 24H`
(volt border when > 0), `WIND KPH`. Elevation card: `BASE n M` / `TOP n M`,
gradient bar, `n M SKIABLE VERT`. `START RECORDING HERE` volt. Stale-data note
kept.

### Profile (1h)
`InitialsAvatar` 56 with volt ring, display name, email. Season card:
`DAYS`, `VERT`, `TOP <unit>`, `SESSIONS` (same source as Home).
`UNITS` card: `Speed` row with `KM/H | MPH | M/S` pill segments, `Distance`
row with `M | FT`. `LOG OUT` ghost + `v0.1.0 · SYNC OK` (package_info is out
of scope). Debug export stays commented.

### Location onboarding (1j)
Full-bleed map-styled gradient background with a drawn volt line and pulsing
dot (static `CustomPainter`), bottom panel: `STEP 1 OF 2`, `YOUR LINE, DRAWN
LIVE.`, body copy, `ALLOW LOCATION` volt, `NOT NOW` text, two-dot progress.
(Step 2 is the OS permission dialog.)

## 5. Data helpers

`lib/features/session/presentation/season_summary.dart`: pure function
`buildSeasonSummary(List<LocalRideSession>, DateTime now)` → days ridden,
total vert (m), top speed (m/s), total distance (m), ride time (s), session
count, season label. Unit-tested. Used by Home and Profile.

## 6. Testing

- Unit: `season_summary_test.dart`, `app_tokens_test.dart` (both themes
  expose the extension, light/dark pairs differ).
- Widget: update `home`, `login`, `resorts_list`, `resort_detail`, `record`,
  `session_detail`, `history` tests for new copy (e.g. `YOUR MOUNTAINS`,
  `START RECORDING`, `FINISH`, volt heart colour). Keep ordering, weather
  resolution, favourite toggle, delete, sync, vertical/altitude formatting
  assertions. Add `app_tab_bar_test.dart` (labels, active dot, branch
  switch), `location_onboarding_screen_test.dart` (ALLOW calls permission and
  marks seen; NOT NOW marks seen only), record toggle test (HUD shows
  `TAP FOR MAP`, tapping returns to map).
- `flutter analyze` clean, `flutter test` green except the pre-existing
  failures listed under Decisions.

## 7. Out of scope

Streak/badges, GPX export, share, NEAR ME distance sort, sparklines, theme
preference toggle, backend or contract changes.
