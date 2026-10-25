import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as paths;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'attendance.dart';

class AttendanceStore {
  AttendanceStore._({Database? database, SharedPreferences? webPreferences})
      : _database = database,
        _webPreferences = webPreferences;

  static const _webEntriesKey = 'attendo.attendance';
  static const _webTargetKey = 'attendo.target_percent';
  static const _webWorkdaysKey = 'attendo.workdays';
  static const _webThemeKey = 'attendo.theme_mode';
  static const _webWifiNetworksKey = 'attendo.wifi_networks';
  static const _webLatitudeKey = 'attendo.workplace_latitude';
  static const _webLongitudeKey = 'attendo.workplace_longitude';
  static const _webWifiEnabledKey = 'attendo.wifi_detection_enabled';
  static const _webLocationEnabledKey = 'attendo.location_detection_enabled';
  static const _webReminderEnabledKey = 'attendo.evening_reminder_enabled';

  final Database? _database;
  final SharedPreferences? _webPreferences;

  static Future<AttendanceStore> open() async {
    if (kIsWeb) {
      return AttendanceStore._(
        webPreferences: await SharedPreferences.getInstance(),
      );
    }
    final dbPath = paths.join(await getDatabasesPath(), 'attendo.db');
    final database = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE attendance (
            date TEXT PRIMARY KEY,
            status TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.insert('settings', {'key': 'target_percent', 'value': '60'});
        await db.insert('settings', {
          'key': 'workdays',
          'value': '1,2,3,4,5',
        });
      },
    );
    return AttendanceStore._(database: database);
  }

  Future<Map<String, AttendanceEntry>> loadEntries() async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      final records = webPreferences.getStringList(_webEntriesKey) ?? const [];
      return Map.fromEntries(records.map((record) {
        final entry = AttendanceEntry.fromMap(
          Map<String, Object?>.from(jsonDecode(record) as Map),
        );
        return MapEntry(entry.dateKey, entry);
      }));
    }
    final rows = await _database!.query('attendance');
    return {
      for (final row in rows)
        row['date']! as String: AttendanceEntry.fromMap(row),
    };
  }

  Future<int> saveEntry(AttendanceEntry entry) => saveEntries([entry]);

  Future<int> saveEntries(List<AttendanceEntry> newEntries) async {
    if (newEntries.isEmpty) return 0;
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      final entries = await loadEntries();
      for (final entry in newEntries) {
        entries[entry.dateKey] = entry;
      }
      final saved = await webPreferences.setStringList(
        _webEntriesKey,
        entries.values.map((value) => jsonEncode(value.toMap())).toList(),
      );
      if (!saved) {
        throw StateError('Could not save attendance in this browser.');
      }
      return newEntries.length;
    }
    await _database!.transaction((transaction) async {
      for (final entry in newEntries) {
        await transaction.insert(
          'attendance',
          entry.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    return newEntries.length;
  }

  Future<int> deleteEntry(DateTime date) async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      final entries = await loadEntries();
      final removed = entries.remove(attendanceDateKey(date));
      if (removed == null) {
        return 0;
      }
      final saved = await webPreferences.setStringList(
        _webEntriesKey,
        entries.values.map((value) => jsonEncode(value.toMap())).toList(),
      );
      if (!saved) {
        throw StateError('Could not remove attendance in this browser.');
      }
      return 1;
    }
    return _database!.delete(
      'attendance',
      where: 'date = ?',
      whereArgs: [attendanceDateKey(date)],
    );
  }

  Future<int> loadTarget() async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      return webPreferences.getInt(_webTargetKey) ?? 60;
    }
    final rows = await _database!.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['target_percent'],
    );
    return rows.isEmpty ? 60 : int.parse(rows.first['value']! as String);
  }

  Future<Set<int>> loadWorkdays() async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      final value = webPreferences.getStringList(_webWorkdaysKey);
      return value == null ? {1, 2, 3, 4, 5} : value.map(int.parse).toSet();
    }
    final rows = await _database!.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['workdays'],
    );
    if (rows.isEmpty) return {1, 2, 3, 4, 5};
    final value = rows.first['value']! as String;
    return value.isEmpty ? <int>{} : value.split(',').map(int.parse).toSet();
  }

  Future<String> loadThemeMode() async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      return webPreferences.getString(_webThemeKey) ?? 'system';
    }
    final rows = await _database!.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['theme_mode'],
    );
    return rows.isEmpty ? 'system' : rows.first['value']! as String;
  }

  Future<List<String>> loadWifiNetworks() async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      return webPreferences.getStringList(_webWifiNetworksKey) ?? const [];
    }
    final rows = await _database!.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['wifi_networks'],
    );
    if (rows.isEmpty) return const [];
    return (jsonDecode(rows.first['value']! as String) as List<dynamic>)
        .cast<String>();
  }

  Future<bool> loadWifiDetectionEnabled() async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      return webPreferences.getBool(_webWifiEnabledKey) ?? false;
    }
    return (await loadSetting('wifi_detection_enabled')) == 'true';
  }

  Future<bool> loadLocationDetectionEnabled() async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      return webPreferences.getBool(_webLocationEnabledKey) ?? false;
    }
    return (await loadSetting('location_detection_enabled')) == 'true';
  }

  Future<bool> loadEveningReminderEnabled() async {
    return true;
  }

  Future<AttendanceEntry?> loadEntry(DateTime date) async =>
      (await loadEntries())[attendanceDateKey(date)];

  Future<String?> loadSetting(String key) async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      return webPreferences.getString('attendo.$key');
    }
    final rows = await _database!.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value']! as String;
  }

  Future<void> saveSetting(String key, String? value) async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      final saved = value == null
          ? await webPreferences.remove('attendo.$key')
          : await webPreferences.setString('attendo.$key', value);
      if (!saved) throw StateError('Could not save $key in this browser.');
      return;
    }
    if (value == null) {
      await _database!.delete('settings', where: 'key = ?', whereArgs: [key]);
    } else {
      await _database!.insert(
        'settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<({double latitude, double longitude})?> loadWorkplaceLocation() async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      final latitude = webPreferences.getDouble(_webLatitudeKey);
      final longitude = webPreferences.getDouble(_webLongitudeKey);
      if (latitude == null || longitude == null) return null;
      return (latitude: latitude, longitude: longitude);
    }
    final rows = await _database!.query(
      'settings',
      columns: ['key', 'value'],
      where: 'key IN (?, ?)',
      whereArgs: ['workplace_latitude', 'workplace_longitude'],
    );
    final coordinates = {for (final row in rows) row['key']!: row['value']!};
    final latitudeValue = coordinates['workplace_latitude'];
    final longitudeValue = coordinates['workplace_longitude'];
    if (latitudeValue == null || longitudeValue == null) return null;
    return (
      latitude: double.parse(latitudeValue as String),
      longitude: double.parse(longitudeValue as String),
    );
  }

  Future<void> savePreferences(
    int targetPercent,
    Set<int> workdays, {
    required String themeMode,
    required List<String> wifiNetworks,
    required double? workplaceLatitude,
    required double? workplaceLongitude,
    required bool wifiDetectionEnabled,
    required bool locationDetectionEnabled,
    required bool eveningReminderEnabled,
  }) async {
    final webPreferences = _webPreferences;
    if (webPreferences != null) {
      final targetSaved =
          await webPreferences.setInt(_webTargetKey, targetPercent);
      final workdaysSaved = await webPreferences.setStringList(
        _webWorkdaysKey,
        (workdays.toList()..sort()).map((day) => '$day').toList(),
      );
      final themeSaved =
          await webPreferences.setString(_webThemeKey, themeMode);
      final wifiSaved = await webPreferences.setStringList(
        _webWifiNetworksKey,
        wifiNetworks,
      );
      final wifiEnabledSaved = await webPreferences.setBool(
        _webWifiEnabledKey,
        wifiDetectionEnabled,
      );
      final locationEnabledSaved = await webPreferences.setBool(
        _webLocationEnabledKey,
        locationDetectionEnabled,
      );
      final reminderSaved = await webPreferences.setBool(
        _webReminderEnabledKey,
        eveningReminderEnabled,
      );
      final latitudeSaved = workplaceLatitude == null
          ? await webPreferences.remove(_webLatitudeKey)
          : await webPreferences.setDouble(_webLatitudeKey, workplaceLatitude);
      final longitudeSaved = workplaceLongitude == null
          ? await webPreferences.remove(_webLongitudeKey)
          : await webPreferences.setDouble(
              _webLongitudeKey, workplaceLongitude);
      if (!targetSaved ||
          !workdaysSaved ||
          !themeSaved ||
          !wifiSaved ||
          !wifiEnabledSaved ||
          !locationEnabledSaved ||
          !reminderSaved ||
          !latitudeSaved ||
          !longitudeSaved) {
        throw StateError('Could not save preferences in this browser.');
      }
      return;
    }
    final batch = _database!.batch();
    batch.insert(
      'settings',
      {'key': 'target_percent', 'value': '$targetPercent'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'settings',
      {'key': 'workdays', 'value': (workdays.toList()..sort()).join(',')},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'settings',
      {'key': 'theme_mode', 'value': themeMode},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'settings',
      {'key': 'wifi_networks', 'value': jsonEncode(wifiNetworks)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'settings',
      {'key': 'wifi_detection_enabled', 'value': '$wifiDetectionEnabled'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'settings',
      {
        'key': 'location_detection_enabled',
        'value': '$locationDetectionEnabled',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'settings',
      {'key': 'evening_reminder_enabled', 'value': '$eveningReminderEnabled'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (workplaceLatitude == null || workplaceLongitude == null) {
      batch.delete(
        'settings',
        where: 'key IN (?, ?)',
        whereArgs: ['workplace_latitude', 'workplace_longitude'],
      );
    } else {
      batch.insert(
        'settings',
        {'key': 'workplace_latitude', 'value': '$workplaceLatitude'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      batch.insert(
        'settings',
        {'key': 'workplace_longitude', 'value': '$workplaceLongitude'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit();
  }
}
