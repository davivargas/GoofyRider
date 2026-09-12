# Feature research: what ski and snowboard tracker users ask for

Research only. Nothing here is scheduled. Compiled 2026-09-12 from app store
listings, reviews, comparison articles, and the feature pages of Slopes, Ski
Tracks, Strava, Trace, Carv, SnowCrew, and OpenSkiMap. Sources are listed at
the end.

## What Fall Line already has

Recording with auto lift and run detection, auto-pause on long stillness,
offline-first storage with background sync, session history grouped by
season, season totals on home and profile, favourite resorts with weather and
a "pow day" badge, a resort catalog with search, unit preferences, a local
Slopes archive importer (backend), GPS warm-up before recording, a one-time
location onboarding step, and a map replay coloured by run, lift, and idle.

## Gap list, grouped, with a fit rating

Fit: **A** = users expect it and the data is already collected, **B** =
clearly valued, moderate build, **C** = nice to have or a large build.

### 1. Run-by-run analysis (fit A)

The most repeated request in Slopes reviews is per-run stats: top speed,
distance, average speed, duration, and vertical for every run, comparable
side by side, with "best run" and "where you hit top speed" markers. The
backend already produces exactly this (`ride_session_actions` with
`top_speed_lat/long`), so this is mostly a mobile screen once the rebuild
lands. Slopes gates it behind Premium; users resent that.

- Run list with sequence number, time, vertical, distance, max and average
  speed.
- Tap a run to see it isolated on the map with the top-speed pin.
- Session "best run" card.
- Average speed that excludes lift and stop time (a common complaint about
  competitors is lift time dragging averages down; the analyzer's
  `avg_descent_speed_mps` already does this).

### 2. Run and lift names (fit A once the lift catalog exists)

Users want to see which trail they skied and which lift they rode, not
"Run 7". Slopes provides lift identification for about 350 resorts and
trail names only on Premium. OpenStreetMap piste and aerialway data (via
OpenSkiData) has names and difficulty for most resorts worldwide, for free.
This depends on the lift catalog work in the GPS sub-project.

- Name each lift action by matching to `aerialway` geometry.
- Name each run by nearest `piste:type=downhill` way, with difficulty colour.
- "Runs skied today" list with counts per trail (people like completing a
  mountain).

### 3. Resort map with pistes and lifts (fit B)

A ski map that shows runs and lifts, not a road map. Requested in every
comparison article; Slopes and Ski Tracks both have it. MapTiler's Winter
style or a MapLibre layer from OpenSkiMap covers it.

- Piste and lift overlay on the record and detail maps.
- Offline map region for a favourite resort (download before the trip).
- Highlight the runs you have already done today.

### 4. Live lift and trail status, snow report (fit B, paid data)

"Is that lift open" and "how much snow fell overnight" are the two questions
people open a ski app for on the morning of. Lift status needs a paid feed
(Mountain News / OnTheSnow, WeatherUnlocked) or resort-specific scraping.
Snow depth and freezing level are free from Open-Meteo today.

- Lift open/closed on the resort detail page.
- Base and summit snow depth, last 24 h and 72 h snowfall, freezing level.
- Webcam links (resort-provided; often just URLs).

### 5. Friends and social (fit B)

Slopes' most-praised premium features are live location sharing with
friends and comparing runs. SnowCrew is built entirely around friends
tracking. Strava wins on leaderboards.

- Friends list, share live location while recording (opt in, session-scoped).
- Compare a session or run with a friend.
- Shareable summary card (image) for messaging apps.
- Resort or friend leaderboards for vertical and top speed; needs mocked
  location handling (the `is_mocked` flag is already recorded).

### 6. Wearables and health (fit B)

Slopes highlights Apple Watch; on Android the equivalent is Wear OS. Heart
rate overlay on a run is a Slopes Premium feature. Health Connect integration
lets sessions count as workouts.

- Wear OS companion showing speed, vertical, and run count; start and stop
  from the wrist.
- Heart rate from a paired sensor, plotted against speed for each run.
- Write sessions to Health Connect; read heart rate from it.

### 7. Trick and jump detection (fit C)

Trace detects airtime, spins, and flips from motion sensors and builds a
leaderboard around it; snowboarders in particular ask for it. Requires IMU
sampling at high rate during recording and a detection model; a big build,
but a differentiator for a snowboard-first app.

- Airtime and jump count per run, jump markers on the map.
- Later: rotation estimate.

### 8. Replay and visualisation (fit C)

3D replay of a run over terrain is the headline Slopes Premium feature and
shows up in every "best ski apps" list. Cheaper variants first:

- Speed and altitude chart along the run, scrubbable, synced to the map.
- Animated 2D replay of the session.
- 3D terrain replay later (MapLibre terrain or a dedicated renderer).
- Heat map of where you have ridden across the season.

### 9. Season and lifetime stats (fit A)

You have season totals; users also want:

- Days per resort, vertical per resort, most-ridden lift and run.
- Personal records with the date and run they were set on.
- Year-over-year comparison and a "season recap" share card at season end.
- Streaks and badges ("10 days this season", "100 km vertical").

### 10. Data portability and integrations (fit A for export, B for sync)

- Export a session as GPX; import GPX and Slopes archives from the app, not
  only via a backend script.
- Sync completed sessions to Strava (Strava already ingests Ski Tracks and
  Slopes data, so people expect it).
- Full account data export and account deletion (needed anyway for a Play
  Store listing).

### 11. Recording practicalities (fit A)

Recurring complaints across trackers are battery drain and lost sessions.
Fall Line already has auto-pause and recovery; the remaining asks are:

- Auto-resume from auto-pause using the significant-motion sensor
  (already a TODO in `recording_controller.dart`).
- Battery-saver mode with adaptive sampling (rebuild Step 8).
- Lock-screen or notification live stats (speed, vertical, run count).
- Home-screen widget with today's totals.
- Auto-start recording when you arrive at a favourite resort (geofence).
- Manual edit of a session: trim start and end, split, change resort, delete
  a bogus run. Slopes' "edit out car time" is praised.
- Snow-condition and equipment tags on a session (rebuild Step 10a adds
  conditions; board and boots profiles are Marker #1).

### 12. Photos and notes (fit B)

- Attach photos taken during the session and pin them on the map by
  timestamp.
- Free-text notes per session.

### 13. Group and trip planning (fit C)

- Meet-up point and "where is everyone" on the map (overlaps with 5).
- Shared trip with a day-by-day log for a group.

## Suggested priority if you pick from this list

1. Run-by-run analysis and names (1, 2): builds directly on the backend work
   and the lift catalog the GPS sub-project needs anyway.
2. Piste map overlay (3) and Open-Meteo snow depth (part of 4).
3. GPX export and Strava sync (10), personal records (9), auto-resume and
   session editing (11).
4. Friends live location and share cards (5).
5. Wear OS (6), then replay charts (8), then tricks (7).

## Sources

- [Slopes on Google Play](https://play.google.com/store/apps/details?id=com.consumedbycode.slopes&hl=en_US) and [App Store](https://apps.apple.com/us/app/slopes-ski-snowboard/id643351983)
- [Slopes Reviews on Product Hunt](https://www.producthunt.com/products/slopes-2/reviews)
- [What is Slopes Premium](https://slopes.helpscoutdocs.com/article/19-what-is-slopes-premium) and [Slopes Premium](https://getslopes.com/premium)
- [Ski Tracking Apps: Strava vs Ski Tracks vs Slopes](https://themountainnetwork.com/strava-vs-ski-tracks-vs-slopes/)
- [Find Out If You're As Fast As You Think You Are With These 5 Ski-Tracking Apps (SKI Magazine)](https://www.skimag.com/performance/fitness/best-ski-tracking-apps/)
- [The Best Skiing Apps (OnTheSnow)](https://www.onthesnow.com/news/the-best-skiing-apps/)
- [Best Ski Apps for Winter 2026 (Piste blog)](https://pisteapp.com/blog/posts/comparison_of_skiing_app/)
- [Ski Tracker App Discrepancy (SkiTalk forum)](https://www.skitalk.com/threads/ski-tracker-app-discrepancy.26491/)
- [Trace: Ski & Snowboard App](https://apps.apple.com/us/app/trace-ski-snowboard/id6760786673)
- [Carv Digital Ski Coach](https://apps.apple.com/us/app/carv-digital-ski-coach/id1238683093)
- [SnowCrew](https://apps.apple.com/mx/app/snow-crew/id6471740852)
- [OpenSkiMap](https://openskimap.org/) and [openskidata-processor](https://github.com/russellporter/openskidata-processor)
- [Open-Meteo docs](https://open-meteo.com/en/docs)
- [WeatherUnlocked Ski Resort API](https://developer.weatherunlocked.com/skiresort)
- [Mountain News / OnTheSnow data API](https://www.mountainnews.com/data-ai/)
- [OpenSnow API](https://opensnow.com/api/start)
- [MapTiler maps for winter sports apps](https://www.maptiler.com/news/2022/03/maps-for-winter-sports-apps/)
