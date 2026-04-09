# Android Branding Setup

This app currently has only Android scaffolded, so the branding workflow here is Android-only.

## Current setup

The app now uses the same simple splash pattern on all Android versions:

- solid background color: `#0A1624`
- centered splash image: `assets/branding/splash_center_icon.png`
- launcher icon source: `assets/branding/icon.png`

There is no runtime use of a full-screen splash background image anymore. The old `assets/branding/splash.png` file may still exist in the repo as a design/source file, but it is not bundled in the app and is not used at startup.

## Files that matter

- [`assets/branding/icon.png`](../assets/branding/icon.png)
  Used for the Android launcher icon generator.
- [`assets/branding/splash_center_icon.png`](../assets/branding/splash_center_icon.png)
  Used for the centered native splash image and the Flutter bootstrap splash.
- [`flutter_launcher_icons.yaml`](../flutter_launcher_icons.yaml)
  Points launcher generation at `icon.png`.
- [`flutter_native_splash.yaml`](../flutter_native_splash.yaml)
  Configures a color-based splash with `splash_center_icon.png`.
- [`pubspec.yaml`](../pubspec.yaml)
  Bundles only `icon.png` and `splash_center_icon.png`.
- [`lib/main.dart`](../lib/main.dart)
  Shows the matching Flutter bootstrap splash while local storage opens.

## Native Android files

These files should all reflect the same simple splash:

- [`android/app/src/main/res/drawable/launch_background.xml`](../android/app/src/main/res/drawable/launch_background.xml)
- [`android/app/src/main/res/drawable-v21/launch_background.xml`](../android/app/src/main/res/drawable-v21/launch_background.xml)
- [`android/app/src/main/res/drawable-night/launch_background.xml`](../android/app/src/main/res/drawable-night/launch_background.xml)
- [`android/app/src/main/res/drawable-night-v21/launch_background.xml`](../android/app/src/main/res/drawable-night-v21/launch_background.xml)

They should use:

- a solid `#0A1624` rectangle background
- `@drawable/splash` centered on top

Android 12+ also uses:

- [`android/app/src/main/res/values-v31/styles.xml`](../android/app/src/main/res/values-v31/styles.xml)
- [`android/app/src/main/res/values-night-v31/styles.xml`](../android/app/src/main/res/values-night-v31/styles.xml)

Those styles should keep:

- `android:windowSplashScreenBackground` set to `#0A1624`
- `android:windowSplashScreenAnimatedIcon` set to `@drawable/android12splash`

## Flutter bootstrap splash

After the native splash disappears, Flutter shows a matching bootstrap screen from [`lib/main.dart`](../lib/main.dart):

- background: `Color(0xFF0A1624)`
- centered image: `assets/branding/splash_center_icon.png`

That keeps startup visually consistent while the local database opens.

## Design guidance

- Keep the launcher icon readable at small size.
- Keep the splash icon slightly more padded than the launcher icon if Android clips it too tightly.
- If the centered splash image feels too zoomed in, update `splash_center_icon.png`, not `icon.png`.
- If you want the splash image smaller, add transparent padding around the artwork instead of shrinking it only in code.

## How to update the icon or splash

From the `mobile` directory:

```powershell
C:\Users\daviv\dev\flutter\bin\cache\dart-sdk\bin\dart.exe run flutter_launcher_icons
C:\Users\daviv\dev\flutter\bin\cache\dart-sdk\bin\dart.exe run flutter_native_splash:create
```

If `dart` is on your `PATH`, the shorter version also works:

```powershell
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

## Important manual cleanup after `flutter_native_splash:create`

`flutter_native_splash` still tends to regenerate a legacy `background.png` path for pre-Android-12 launch screens, even though the app no longer uses that approach.

After running the generator, verify that the four `launch_background.xml` files listed above still use the solid rectangle shape, not:

```xml
<bitmap android:gravity="fill" android:src="@drawable/background"/>
```

If the generator reintroduces that line:

1. Replace it with a solid `#0A1624` rectangle shape.
2. Delete any regenerated `background.png` files under:
   - `android/app/src/main/res/drawable/`
   - `android/app/src/main/res/drawable-v21/`
   - `android/app/src/main/res/drawable-night/`
   - `android/app/src/main/res/drawable-night-v21/`

## Quick verification

After branding changes, run:

```powershell
C:\Users\daviv\dev\flutter\bin\cache\dart-sdk\bin\dart.exe C:\Users\daviv\dev\flutter\packages\flutter_tools\bin\flutter_tools.dart --no-version-check test --no-pub test/widget/app_bootstrap_test.dart
.\gradlew.bat app:processDebugResources
```

Run the Gradle command from `mobile/android`.

## Device testing notes

1. Uninstall and reinstall the app if the launcher icon or splash appears cached.
2. Launch from the home screen, not only from Android Studio.
3. Check three things:
   - the home-screen icon looks correct
   - the centered splash image is not clipped
   - the transition from native splash to Flutter bootstrap looks seamless
