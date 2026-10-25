import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/widgets.dart';

import 'attendance.dart';
import 'attendance_store.dart';

class AttendanceNotificationIntent {
  const AttendanceNotificationIntent(this.payload);

  final String payload;

  String get source {
    try {
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      return decoded['source'] as String? ?? 'reminder';
    } on FormatException {
      return 'reminder';
    }
  }
}

final attendanceNotificationIntents =
    StreamController<AttendanceNotificationIntent>.broadcast();

final _notifications = FlutterLocalNotificationsPlugin();
bool _notificationsInitialized = false;

Future<void> initializeAttendanceNotifications() async {
  if (_notificationsInitialized) return;
  final initialized = await _notifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: (response) {
      if (response.payload != null) {
        attendanceNotificationIntents.add(
          AttendanceNotificationIntent(response.payload!),
        );
      }
    },
    onDidReceiveBackgroundNotificationResponse:
        attendanceNotificationBackgroundResponse,
  );
  if (initialized != true) {
    throw StateError('Could not initialize attendance notifications.');
  }
  _notificationsInitialized = true;
}

Future<String?> attendanceNotificationLaunchPayload() async {
  final launch = await _notifications.getNotificationAppLaunchDetails();
  if (launch?.didNotificationLaunchApp != true) return null;
  return launch?.notificationResponse?.payload;
}

Future<bool> requestAttendanceNotificationPermission() async {
  final android = _notifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  return await android?.requestNotificationsPermission() ?? false;
}

Future<bool> areAttendanceNotificationsEnabled() async {
  final android = _notifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  return await android?.areNotificationsEnabled() ?? false;
}

Future<void> showWorkplaceCheckInNotification({
  required String source,
  required String dateKey,
}) async {
  await _notifications.show(
    id: 1,
    title: 'You seem to be at your workplace',
    body: 'We detected $source for an hour. Were you in office today?',
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'workplace_check_in',
        'Workplace check-in',
        channelDescription: 'Optional office arrival attendance reminders.',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        actions: [
          AndroidNotificationAction(
            'office',
            'In office',
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'remote',
            'Remote',
            cancelNotification: true,
          ),
        ],
      ),
    ),
    payload: jsonEncode({'source': source, 'date': dateKey}),
  );
}

Future<void> cancelAttendanceReminderNotifications() async {
  if (!_notificationsInitialized) return;
  await _notifications.cancel(id: 1);
  await _notifications.cancel(id: 2);
}

Future<void> showEveningCheckInNotification({required String dateKey}) async {
  await _notifications.show(
    id: 2,
    title: 'Still need to check in?',
    body: 'Your attendance for today has not been marked.',
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'evening_check_in',
        'Evening check-in reminder',
        channelDescription: 'A reminder when today has no attendance entry.',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        actions: [
          AndroidNotificationAction(
            'office',
            'In office',
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'remote',
            'Remote',
            cancelNotification: true,
          ),
        ],
      ),
    ),
    payload: jsonEncode({'source': 'evening', 'date': dateKey}),
  );
}

@pragma('vm:entry-point')
void attendanceNotificationBackgroundResponse(
  NotificationResponse response,
) async {
  if (response.actionId != 'office' && response.actionId != 'remote') return;
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await initializeAttendanceNotifications();
  final store = await AttendanceStore.open();
  final today = DateTime.now();
  final date = DateTime(today.year, today.month, today.day);
  final todayKey = attendanceDateKey(date);
  final payload = response.payload;
  if (payload != null) {
    final notificationDate =
        (jsonDecode(payload) as Map<String, dynamic>)['date'] as String?;
    if (notificationDate != todayKey) return;
  }
  if ((await store.loadEntry(date)) != null ||
      !(await store.loadWorkdays()).contains(date.weekday)) {
    return;
  }
  final status = response.actionId == 'office'
      ? AttendanceStatus.office
      : AttendanceStatus.remote;
  await store.saveEntry(AttendanceEntry(
    date: date,
    status: status,
    note: payload == null
        ? ''
        : 'Notification check-in: ${AttendanceNotificationIntent(payload).source}',
  ));
  await store.saveSetting('detection_started_at', null);
  await store.saveSetting('detection_notified_date', todayKey);
  await cancelAttendanceReminderNotifications();
}
