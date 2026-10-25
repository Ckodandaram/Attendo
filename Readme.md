# Atten-do

Atten-do is a private, offline-first attendance tracker for Android. It helps you
track office days against a quarterly target, review your calendar, and understand
how many more office days you need. Attendance and preferences are stored locally
in SQLite; there is no account or backend.

## Requirements

- Flutter SDK (stable channel)
- Android SDK and JDK 17 for Android builds
- An Android device or emulator

## Run the app

From the repository root, fetch the Flutter packages and run the app:

```powershell
flutter pub get
flutter run
```

## Preview in a browser

```powershell
flutter run -d chrome
```

The browser preview stores its data in browser storage. Android stores its data
in the app's local SQLite database.

## Build an APK

```powershell
flutter build apk --release
```

The APK is written to
`build\app\outputs\flutter-apk\app-release.apk`.

To build a distributable APK with your own signing identity, configure an
Android release signing key in the generated `android` project before building.
Do not commit a private signing key or its passwords.

## Current scope

The app currently supports a configurable quarterly target and workweek, manual
attendance entry, a month calendar with multi-day status updates, basic goal
feasibility, insights, history, and local SQLite persistence. The dashboard's
attendance rate is based on all eligible workdays in the quarter and is floored
to whole percentages; the configurable target remains separate for goal
progress and feasibility warnings. Calendar dates outside the configured
workweek are dimmed and unavailable for all status markings.
Office Wi-Fi and location detection are independently optional; disable both
for manual-only tracking. On Android, background checks begin after 11:00 AM
and offer a check-in notification after an hour of detected workplace presence,
if today is still unmarked. An evening reminder is also checked from 4:50 PM.
Notification actions save In office or Remote directly, while opening
the notification takes the user to the dashboard for other statuses.

Android schedules background checks at a 15-minute minimum interval. Actual
execution and notifications can be delayed by battery optimization, device
state, or force-stop behavior. Workplace location detection requires background
location permission, and notifications require notification permission. Manual
check-ins are always available. Plan ranges, CSV export, JSON backup/restore,
and finalized quarter snapshots are not implemented yet.
