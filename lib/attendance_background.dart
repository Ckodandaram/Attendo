import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:workmanager/workmanager.dart';

import 'attendance.dart';
import 'attendance_notifications.dart';
import 'attendance_store.dart';

const _monitorTask = 'attendo.workplace_monitor';
const _monitorUniqueName = 'attendo.workplace_monitor';
const _monitorInterval = Duration(minutes: 15);
const _detectionStartHour = 11;
const _presenceDuration = Duration(hours: 1);
bool _workmanagerInitialized = false;

Future<void> initializeAttendanceBackgroundMonitoring({
  required bool enabled,
}) async {
  if (kIsWeb || !Platform.isAndroid) return;
  await Workmanager().initialize(attendanceBackgroundDispatcher);
  _workmanagerInitialized = true;
  await configureAttendanceBackgroundMonitoring(enabled: enabled);
}

Future<void> configureAttendanceBackgroundMonitoring({
  required bool enabled,
}) async {
  if (kIsWeb || !Platform.isAndroid || !_workmanagerInitialized) return;
  if (!enabled) {
    await Workmanager().cancelByUniqueName(_monitorUniqueName);
    return;
  }
  await Workmanager().registerPeriodicTask(
    _monitorUniqueName,
    _monitorTask,
    frequency: _monitorInterval,
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}

@pragma('vm:entry-point')
void attendanceBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != _monitorTask) return true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      await initializeAttendanceNotifications();
      await _runAttendanceMonitor();
      return true;
    } catch (error) {
      debugPrint('Atten-do background check failed: $error');
      return false;
    }
  });
}

Future<void> _runAttendanceMonitor() async {
  final store = await AttendanceStore.open();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final dateKey = attendanceDateKey(today);
  final todayEntry = await store.loadEntry(today);
  if (todayEntry != null) {
    await _clearPresenceState(store);
    return;
  }

  final workdays = await store.loadWorkdays();
  if (!workdays.contains(today.weekday)) return;

  final reminderEnabled = await store.loadEveningReminderEnabled();
  if (reminderEnabled &&
      (now.hour > 16 || (now.hour == 16 && now.minute >= 50)) &&
      await store.loadSetting('evening_reminder_date') != dateKey) {
    if (await areAttendanceNotificationsEnabled()) {
      await showEveningCheckInNotification(dateKey: dateKey);
      await store.saveSetting('evening_reminder_date', dateKey);
    }
  }

  if (now.hour < _detectionStartHour) {
    await _clearPresenceState(store);
    return;
  }

  final wifiEnabled = await store.loadWifiDetectionEnabled();
  final locationEnabled = await store.loadLocationDetectionEnabled();
  final wifiNetworks = await store.loadWifiNetworks();
  final workplaceLocation = await store.loadWorkplaceLocation();
  final detectedSources = <String>[];
  final detectionErrors = <String>[];

  if (wifiEnabled && wifiNetworks.isNotEmpty) {
    try {
      final connectedName = (await NetworkInfo().getWifiName())
          ?.replaceAll('"', '')
          .trim()
          .toLowerCase();
      if (connectedName != null &&
          wifiNetworks.any((name) => name.toLowerCase() == connectedName)) {
        detectedSources.add('office Wi-Fi');
      }
    } catch (error) {
      detectionErrors.add('Wi-Fi: $error');
    }
  }

  if (locationEnabled && workplaceLocation != null) {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Location services are turned off.');
      }
      if (await Geolocator.checkPermission() != LocationPermission.always) {
        throw StateError('Allow background location in Android app settings.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      final distance = Geolocator.distanceBetween(
        workplaceLocation.latitude,
        workplaceLocation.longitude,
        position.latitude,
        position.longitude,
      );
      if (distance <= 10) detectedSources.add('workplace location');
    } catch (error) {
      detectionErrors.add('Location: $error');
    }
  }

  if (detectedSources.isEmpty) {
    await _clearPresenceState(store);
    await store.saveSetting(
      'last_detection_error',
      detectionErrors.isEmpty ? null : detectionErrors.join(' '),
    );
    return;
  }
  await store.saveSetting('last_detection_error', null);

  final startedDate = await store.loadSetting('detection_started_date');
  var startedAt = DateTime.tryParse(
    await store.loadSetting('detection_started_at') ?? '',
  );
  if (startedDate != dateKey || startedAt == null) {
    startedAt = now;
    await store.saveSetting('detection_started_date', dateKey);
    await store.saveSetting(
      'detection_started_at',
      startedAt.toIso8601String(),
    );
    await store.saveSetting('detection_source', detectedSources.join(' and '));
  }

  final alreadyNotified =
      await store.loadSetting('detection_notified_date') == dateKey;
  if (!alreadyNotified &&
      now.difference(startedAt) >= _presenceDuration &&
      await areAttendanceNotificationsEnabled()) {
    await showWorkplaceCheckInNotification(
      source: detectedSources.join(' and '),
      dateKey: dateKey,
    );
    await store.saveSetting('detection_notified_date', dateKey);
  }
}

Future<void> _clearPresenceState(AttendanceStore store) async {
  await store.saveSetting('detection_started_date', null);
  await store.saveSetting('detection_started_at', null);
  await store.saveSetting('detection_source', null);
}
