import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'attendance_background.dart';
import 'attendance_notifications.dart';
import 'attendance.dart';
import 'attendance_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AttendanceStore.open();
  String? launchPayload;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await initializeAttendanceNotifications();
    launchPayload = await attendanceNotificationLaunchPayload();
    await initializeAttendanceBackgroundMonitoring(
      enabled: await store.loadWifiDetectionEnabled() ||
          await store.loadLocationDetectionEnabled() ||
          await store.loadEveningReminderEnabled(),
    );
  }
  runApp(AttendoApp(store: store, launchPayload: launchPayload));
}

const _ink = Color(0xFF172B3A);
const _teal = Color(0xFF087E78);
const _canvas = Color(0xFFF4F7F6);

ThemeData _appTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final canvas = isDark ? const Color(0xFF101A20) : _canvas;
  final surface = isDark ? const Color(0xFF192831) : Colors.white;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: canvas,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _teal,
      brightness: brightness,
      surface: surface,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: canvas,
      foregroundColor: isDark ? Colors.white : _ink,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20))),
      margin: EdgeInsets.zero,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      modalBackgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: _teal.withValues(alpha: .18),
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}

ThemeMode _themeModeFromName(String name) => switch (name) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

Color _inkFor(BuildContext context) => Theme.of(context).colorScheme.onSurface;

Color _mutedFor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

class AttendoApp extends StatelessWidget {
  const AttendoApp({required this.store, this.launchPayload, super.key});

  final AttendanceStore store;
  final String? launchPayload;

  @override
  Widget build(BuildContext context) =>
      _AttenDoRoot(store: store, launchPayload: launchPayload);
}

class _AttenDoRoot extends StatefulWidget {
  const _AttenDoRoot({required this.store, this.launchPayload});

  final AttendanceStore store;
  final String? launchPayload;

  @override
  State<_AttenDoRoot> createState() => _AttenDoRootState();
}

class _AttenDoRootState extends State<_AttenDoRoot> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final mode = _themeModeFromName(await widget.store.loadThemeMode());
    if (mounted) setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Atten-do',
        debugShowCheckedModeBanner: false,
        themeMode: _themeMode,
        theme: _appTheme(Brightness.light),
        darkTheme: _appTheme(Brightness.dark),
        home: AttendoHome(
          store: widget.store,
          launchPayload: widget.launchPayload,
          onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
        ),
      );
}

class AttendoHome extends StatefulWidget {
  const AttendoHome({
    required this.store,
    this.launchPayload,
    required this.onThemeModeChanged,
    super.key,
  });

  final AttendanceStore store;
  final String? launchPayload;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<AttendoHome> createState() => _AttendoHomeState();
}

class _AttendoHomeState extends State<AttendoHome> {
  static const _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  int _tab = 0;
  int _target = 60;
  ThemeMode _themeMode = ThemeMode.system;
  Set<int> _workdays = {1, 2, 3, 4, 5};
  List<String> _wifiNetworks = [];
  bool _wifiDetectionEnabled = false;
  bool _locationDetectionEnabled = false;
  String? _lastDetectionError;
  ({double latitude, double longitude})? _workplaceLocation;
  Map<String, AttendanceEntry> _entries = {};
  final TextEditingController _wifiController = TextEditingController();
  DateTime _quarter = quarterStart(DateTime.now());
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  Object? _loadError;
  bool _loading = true;
  String? _notificationSource;
  StreamSubscription<AttendanceNotificationIntent>? _notificationSubscription;

  @override
  void initState() {
    super.initState();
    _reload();
    if (widget.launchPayload != null) {
      _notificationSource =
          AttendanceNotificationIntent(widget.launchPayload!).source;
    }
    _notificationSubscription = attendanceNotificationIntents.stream.listen(
      (intent) {
        if (!context.mounted) return;
        setState(() {
          _tab = 0;
          _notificationSource = intent.source;
        });
        _reload();
      },
    );
  }

  @override
  void dispose() {
    _wifiController.dispose();
    _notificationSubscription?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final results = await Future.wait<Object?>([
        widget.store.loadEntries(),
        widget.store.loadTarget(),
        widget.store.loadWorkdays(),
        widget.store.loadThemeMode(),
        widget.store.loadWifiNetworks(),
        widget.store.loadWorkplaceLocation(),
        widget.store.loadWifiDetectionEnabled(),
        widget.store.loadLocationDetectionEnabled(),
        widget.store.loadSetting('last_detection_error'),
      ]);
      if (!context.mounted) return;
      setState(() {
        _entries = results[0] as Map<String, AttendanceEntry>;
        _target = results[1] as int;
        _workdays = results[2] as Set<int>;
        _themeMode = _themeModeFromName(results[3] as String);
        _wifiNetworks = results[4] as List<String>;
        _workplaceLocation =
            results[5] as ({double latitude, double longitude})?;
        _wifiDetectionEnabled = results[6] as bool;
        _locationDetectionEnabled = results[7] as bool;
        _lastDetectionError = results[8] as String?;
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  Future<void> _editEntry(DateTime date) async {
    final current = _entries[attendanceDateKey(date)];
    final now = DateTime.now();
    final isFuture = DateTime(date.year, date.month, date.day)
        .isAfter(DateTime(now.year, now.month, now.day));
    final selected = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _StatusSheet(
        date: date,
        current: current?.status,
        isFuture: isFuture,
        isWorkingDay: _workdays.contains(date.weekday),
      ),
    );
    if (!mounted || selected == false) return;
    if (selected == 'clear') {
      await widget.store.deleteEntry(date);
    } else if (selected is AttendanceStatus) {
      await widget.store
          .saveEntry(AttendanceEntry(date: date, status: selected));
      if (_isToday(date)) await cancelAttendanceReminderNotifications();
    } else {
      return;
    }
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(selected == 'clear'
              ? 'Attendance entry removed'
              : '${(selected as AttendanceStatus).label} saved'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _saveEntries(List<AttendanceEntry> entries) async {
    if (entries.any((entry) => !_workdays.contains(entry.date.weekday))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selected dates must be in your configured workweek.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await widget.store.saveEntries(entries);
    if (entries.any((entry) => _isToday(entry.date))) {
      await cancelAttendanceReminderNotifications();
    }
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${entries.length} days updated'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _saveTodayStatus(AttendanceStatus status) async {
    final today = DateTime.now();
    if (!_workdays.contains(today.weekday)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Today is outside your configured workweek.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await widget.store.saveEntry(AttendanceEntry(
      date: DateTime(today.year, today.month, today.day),
      status: status,
    ));
    await cancelAttendanceReminderNotifications();
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${status.label} saved for today'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _selectOtherCheckIn(DateTime date) async {
    final current = _entries[attendanceDateKey(date)]?.status;
    final status = await showModalBottomSheet<AttendanceStatus>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _OtherCheckInSheet(current: current),
    );
    if (status != null && mounted) await _saveTodayStatus(status);
  }

  Future<void> _settings() async {
    var target = _target.toDouble();
    final workdays = Set<int>.of(_workdays);
    final initialThemeMode = _themeMode;
    var themeMode = initialThemeMode;
    final wifiNetworks = List<String>.of(_wifiNetworks);
    var workplaceLocation = _workplaceLocation;
    var wifiDetectionEnabled = _wifiDetectionEnabled;
    var locationDetectionEnabled = _locationDetectionEnabled;
    const eveningReminderEnabled = true;
    _wifiController.clear();
    String? wifiMessage;
    String? locationMessage;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: FractionallySizedBox(
            heightFactor: .9,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                16,
                24,
                16 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                children: [
                  const Center(child: _SheetHandle()),
                  const SizedBox(height: 16),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Settings',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 20),
                          Text('Appearance',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 10),
                          SegmentedButton<ThemeMode>(
                            segments: const [
                              ButtonSegment(
                                  value: ThemeMode.system,
                                  label: Text('System'),
                                  icon: Icon(Icons.settings_suggest_outlined)),
                              ButtonSegment(
                                  value: ThemeMode.light,
                                  label: Text('Light'),
                                  icon: Icon(Icons.light_mode_outlined)),
                              ButtonSegment(
                                  value: ThemeMode.dark,
                                  label: Text('Dark'),
                                  icon: Icon(Icons.dark_mode_outlined)),
                            ],
                            selected: {themeMode},
                            onSelectionChanged: (selection) {
                              final selectedTheme = selection.first;
                              setSheetState(() => themeMode = selectedTheme);
                              widget.onThemeModeChanged(selectedTheme);
                            },
                          ),
                          const SizedBox(height: 22),
                          Text('Your workweek',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 12),
                          Row(
                            children: List.generate(7, (index) {
                              final weekday = index + 1;
                              return Expanded(
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 2),
                                  child: FilterChip(
                                    showCheckmark: false,
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    padding: EdgeInsets.zero,
                                    labelPadding: const EdgeInsets.symmetric(
                                        horizontal: 2),
                                    label: Text(
                                      _weekdays[index].substring(0, 3),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    selected: workdays.contains(weekday),
                                    onSelected: (selected) => setSheetState(() {
                                      if (selected) {
                                        workdays.add(weekday);
                                      } else {
                                        workdays.remove(weekday);
                                      }
                                    }),
                                  ),
                                ),
                              );
                            }),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                child: Text('Quarterly attendance target',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                              ),
                              Text('${target.round()}%',
                                  style: const TextStyle(
                                      color: _teal,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                          Slider(
                            value: target,
                            min: 0,
                            max: 100,
                            divisions: 20,
                            label: '${target.round()}%',
                            onChanged: (value) =>
                                setSheetState(() => target = value),
                          ),
                          const SizedBox(height: 18),
                          Text('Workplace detection',
                              style: Theme.of(context).textTheme.titleMedium),
                          if (_lastDetectionError != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Background detection needs attention: $_lastDetectionError',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Detect office Wi-Fi'),
                            value: wifiDetectionEnabled,
                            onChanged: (enabled) => setSheetState(() {
                              wifiDetectionEnabled = enabled;
                              if (!enabled) wifiMessage = null;
                            }),
                          ),
                          if (wifiDetectionEnabled) ...[
                            Text('Office Wi-Fi network names',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _wifiController,
                                    textInputAction: TextInputAction.done,
                                    decoration: const InputDecoration(
                                      labelText: 'Wi-Fi network name',
                                      border: OutlineInputBorder(),
                                    ),
                                    onSubmitted: (_) => _addWifiNetwork(
                                      _wifiController,
                                      wifiNetworks,
                                      setSheetState,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Add network',
                                  onPressed: () => _addWifiNetwork(
                                    _wifiController,
                                    wifiNetworks,
                                    setSheetState,
                                  ),
                                  icon: const Icon(Icons.add_circle_outline),
                                ),
                                IconButton(
                                  tooltip: 'Detect current Wi-Fi',
                                  onPressed: () async {
                                    try {
                                      final network = await _currentWifiName();
                                      _wifiController.text = network;
                                      _addWifiNetwork(
                                        _wifiController,
                                        wifiNetworks,
                                        setSheetState,
                                      );
                                      setSheetState(() => wifiMessage =
                                          'Detected and added "$network".');
                                    } catch (error) {
                                      setSheetState(() => wifiMessage =
                                          'Wi-Fi detection unavailable: $error');
                                    }
                                  },
                                  icon: const Icon(Icons.wifi_find_rounded),
                                ),
                              ],
                            ),
                            if (wifiNetworks.isNotEmpty)
                              Wrap(
                                spacing: 8,
                                children: wifiNetworks
                                    .map((network) => InputChip(
                                          label: Text(network),
                                          onDeleted: () => setSheetState(() =>
                                              wifiNetworks.remove(network)),
                                        ))
                                    .toList(),
                              ),
                            if (wifiMessage != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                wifiMessage!,
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                          const SizedBox(height: 14),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Detect workplace location'),
                            value: locationDetectionEnabled,
                            onChanged: (enabled) async {
                              if (enabled) {
                                final granted = kIsWeb ||
                                    await _requestBackgroundLocationAccess();
                                if (!granted) {
                                  setSheetState(() => locationMessage =
                                      'Allow background location in Android settings to enable this feature.');
                                  return;
                                }
                              }
                              setSheetState(() {
                                locationDetectionEnabled = enabled;
                                if (!enabled) locationMessage = null;
                              });
                            },
                          ),
                          if (locationDetectionEnabled) ...[
                            Text('Workplace location',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 4),
                            Text(
                              workplaceLocation == null
                                  ? 'No workplace location saved.'
                                  : 'Workplace location saved · detection uses a 10 m radius.',
                              style: TextStyle(
                                  color: _mutedFor(context), fontSize: 12),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: locationDetectionEnabled
                                      ? () async {
                                          try {
                                            final position =
                                                await _currentPosition();
                                            if (!context.mounted) return;
                                            final confirmed =
                                                await showDialog<bool>(
                                              context: context,
                                              builder: (context) => AlertDialog(
                                                title: const Text(
                                                    'Is this your office location?'),
                                                content: Text(
                                                  'Use this device location as your workplace? Detection will use a 10 m radius.\n\n${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}',
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                            context, false),
                                                    child:
                                                        const Text('Not now'),
                                                  ),
                                                  FilledButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                            context, true),
                                                    child: const Text(
                                                        'Save office location'),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirmed == true && mounted) {
                                              setSheetState(() {
                                                workplaceLocation = (
                                                  latitude: position.latitude,
                                                  longitude: position.longitude,
                                                );
                                                locationMessage =
                                                    'Office location confirmed. Save settings to finish.';
                                              });
                                            }
                                          } catch (error) {
                                            setSheetState(() => locationMessage =
                                                'Location detection unavailable: $error');
                                          }
                                        }
                                      : null,
                                  icon: const Icon(
                                      Icons.add_location_alt_outlined),
                                  label: const Text('Detect office location'),
                                ),
                                if (workplaceLocation != null)
                                  OutlinedButton.icon(
                                    onPressed: locationDetectionEnabled
                                        ? () async {
                                            try {
                                              final position =
                                                  await _currentPosition();
                                              final distance =
                                                  Geolocator.distanceBetween(
                                                workplaceLocation!.latitude,
                                                workplaceLocation!.longitude,
                                                position.latitude,
                                                position.longitude,
                                              );
                                              setSheetState(() =>
                                                  locationMessage = distance <=
                                                          10
                                                      ? 'You are at the saved workplace.'
                                                      : 'You are ${distance.round()} m from the saved workplace.');
                                            } catch (error) {
                                              setSheetState(() => locationMessage =
                                                  'Location detection unavailable: $error');
                                            }
                                          }
                                        : null,
                                    icon: const Icon(Icons.my_location_rounded),
                                    label: const Text('Check location'),
                                  ),
                                if (workplaceLocation != null)
                                  TextButton(
                                    onPressed: () => setSheetState(
                                        () => workplaceLocation = null),
                                    child: const Text('Remove'),
                                  ),
                              ],
                            ),
                            if (locationMessage != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                locationMessage!,
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontSize: 12),
                              ),
                            ],
                          ],
                          const SizedBox(height: 8),
                          const SizedBox(height: 18),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: workdays.isEmpty ||
                              (wifiDetectionEnabled && wifiNetworks.isEmpty) ||
                              (locationDetectionEnabled &&
                                  workplaceLocation == null)
                          ? null
                          : () => Navigator.pop(context, true),
                      child: const Text('Save settings'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (saved != true) {
      widget.onThemeModeChanged(initialThemeMode);
      return;
    }
    await widget.store.savePreferences(
      target.round(),
      workdays,
      themeMode: themeMode.name,
      wifiNetworks: wifiNetworks,
      workplaceLatitude: workplaceLocation?.latitude,
      workplaceLongitude: workplaceLocation?.longitude,
      wifiDetectionEnabled: wifiDetectionEnabled,
      locationDetectionEnabled: locationDetectionEnabled,
      eveningReminderEnabled: eveningReminderEnabled,
    );
    await configureAttendanceBackgroundMonitoring(
      enabled: wifiDetectionEnabled ||
          locationDetectionEnabled ||
          eveningReminderEnabled,
    );
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        (wifiDetectionEnabled ||
            locationDetectionEnabled ||
            eveningReminderEnabled)) {
      final permitted = await requestAttendanceNotificationPermission();
      if (!permitted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Allow notifications in Android settings to receive check-in reminders.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
    widget.onThemeModeChanged(themeMode);
    await _reload();
  }

  void _addWifiNetwork(
    TextEditingController controller,
    List<String> networks,
    StateSetter setSheetState,
  ) {
    final network = controller.text.trim().replaceAll('"', '');
    if (network.isEmpty ||
        networks.any((value) => value.toLowerCase() == network.toLowerCase())) {
      return;
    }
    setSheetState(() => networks.add(network));
    controller.clear();
  }

  Future<String> _currentWifiName() async {
    final networkName = await NetworkInfo().getWifiName();
    final cleaned = networkName?.replaceAll('"', '').trim();
    if (cleaned == null || cleaned.isEmpty || cleaned == '<unknown ssid>') {
      throw StateError('No Wi-Fi network name is available on this device.');
    }
    return cleaned;
  }

  Future<Position> _currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Turn on Location services and try again.');
    }
    await _ensureLocationPermission();
    return Geolocator.getCurrentPosition();
  }

  Future<void> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Turn on Location services and try again.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission is required for detection.');
    }
  }

  Future<bool> _requestBackgroundLocationAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.always) return true;
    if (!mounted) return false;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Allow background location'),
        content: const Text(
          'Android needs "Allow all the time" location access to check for your workplace while Atten-do is closed. You can leave these detection options off and use manual check-ins instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (openSettings != true) return false;
    await Geolocator.openAppSettings();
    return await Geolocator.checkPermission() == LocationPermission.always;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_loadError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.storage_rounded, size: 40, color: _teal),
                const SizedBox(height: 12),
                const Text('Atten-do couldn’t open its local database.'),
                const SizedBox(height: 8),
                Text('$_loadError', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                    onPressed: _reload, child: const Text('Try again')),
              ],
            ),
          ),
        ),
      );
    }
    final summary = calculateQuarter(
      quarter: _quarter,
      today: DateTime.now(),
      entries: _entries,
      workdays: _workdays,
      targetPercent: _target,
    );
    final today = DateTime.now();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 22,
        title: const Text(
          'Atten-do',
          style: TextStyle(
              fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -.8),
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: _settings,
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _tab,
          children: [
            _HomePage(
              today: today,
              quarter: _quarter,
              summary: summary,
              entries: _entries,
              notificationSource: _notificationSource,
              isTodayWorkingDay: _workdays.contains(today.weekday),
              onQuarterChanged: (date) =>
                  setState(() => _quarter = quarterStart(date)),
              onCheckIn: _saveTodayStatus,
              onOtherCheckIn: () => _selectOtherCheckIn(today),
              onDismissNotification: () =>
                  setState(() => _notificationSource = null),
              onOpenCalendar: () => setState(() => _tab = 1),
            ),
            _CalendarPage(
              month: _month,
              entries: _entries,
              workdays: _workdays,
              onMonthChanged: (month) => setState(() => _month = month),
              onEdit: _editEntry,
              onApplyBulk: _saveEntries,
            ),
            _InsightsPage(summary: summary, quarter: _quarter),
            _HistoryPage(entries: _entries, onEdit: _editEntry),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.calendar_month_outlined),
              selectedIcon: Icon(Icons.calendar_month_rounded),
              label: 'Calendar'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights_rounded),
              label: 'Insights'),
          NavigationDestination(
              icon: Icon(Icons.history_rounded), label: 'History'),
        ],
      ),
    );
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage({
    required this.today,
    required this.quarter,
    required this.summary,
    required this.entries,
    required this.notificationSource,
    required this.isTodayWorkingDay,
    required this.onQuarterChanged,
    required this.onCheckIn,
    required this.onOtherCheckIn,
    required this.onDismissNotification,
    required this.onOpenCalendar,
  });

  final DateTime today;
  final DateTime quarter;
  final QuarterSummary summary;
  final Map<String, AttendanceEntry> entries;
  final String? notificationSource;
  final bool isTodayWorkingDay;
  final ValueChanged<DateTime> onQuarterChanged;
  final Future<void> Function(AttendanceStatus) onCheckIn;
  final VoidCallback onOtherCheckIn;
  final VoidCallback onDismissNotification;
  final VoidCallback onOpenCalendar;

  @override
  Widget build(BuildContext context) {
    final todayEntry = entries[attendanceDateKey(today)];
    final attendancePercent = summary.attendanceRatePercent;

    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
      children: [
        Text(_dateLabel(today),
            style: TextStyle(
                color: _mutedFor(context), fontWeight: FontWeight.w500)),
        const SizedBox(height: 5),
        Text('Your workdays, on track.',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: _inkFor(context), fontWeight: FontWeight.w800)),
        const SizedBox(height: 21),
        _QuarterPicker(date: quarter, onChanged: onQuarterChanged),
        const SizedBox(height: 14),
        _GoalCard(summary: summary, attendancePercent: attendancePercent),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                label: 'Office days',
                value: '${summary.officeDays}',
                detail: 'of ${summary.eligibleDays} eligible days',
                icon: Icons.apartment_rounded,
                color: _teal,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                label: 'Still needed',
                value: '${summary.remainingOfficeDays}',
                detail: summary.isAchievable
                    ? '${summary.suitableFutureDays} days left'
                    : 'Schedule is tight',
                icon: Icons.flag_rounded,
                color: summary.isAchievable
                    ? const Color(0xFFCE8A34)
                    : const Color(0xFFB94E58),
              ),
            ),
          ],
        ),
        const SizedBox(height: 25),
        if (notificationSource != null) ...[
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.location_on_outlined,
                      color:
                          Theme.of(context).colorScheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      notificationSource == 'evening'
                          ? 'Your evening check-in reminder is ready.'
                          : 'We detected ${notificationSource!.replaceAll('_', ' ')}. Confirm today’s check-in below.',
                      style: TextStyle(
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: () => onDismissNotification(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("Today's check-in",
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _inkFor(context), fontWeight: FontWeight.w700)),
            TextButton(
                onPressed: onOpenCalendar, child: const Text('Calendar')),
          ],
        ),
        const SizedBox(height: 6),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StatusDot(status: todayEntry?.status),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            todayEntry?.status.label ?? 'Choose your day',
                            style: TextStyle(
                                color: _inkFor(context),
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            todayEntry == null
                                ? 'Tap a status to check in.'
                                : 'Saved on this device. Tap another status to change it.',
                            style: TextStyle(
                                color: _mutedFor(context), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      avatar: const Icon(Icons.apartment_rounded, size: 17),
                      label: const Text('In office'),
                      selected: todayEntry?.status == AttendanceStatus.office,
                      onSelected: isTodayWorkingDay
                          ? (_) => onCheckIn(AttendanceStatus.office)
                          : null,
                    ),
                    ChoiceChip(
                      avatar: const Icon(Icons.home_work_outlined, size: 17),
                      label: const Text('Remote'),
                      selected: todayEntry?.status == AttendanceStatus.remote,
                      onSelected: isTodayWorkingDay
                          ? (_) => onCheckIn(AttendanceStatus.remote)
                          : null,
                    ),
                    ChoiceChip(
                      avatar: const Icon(Icons.more_horiz_rounded, size: 17),
                      label: const Text('Other'),
                      selected: todayEntry != null &&
                          todayEntry.status != AttendanceStatus.office &&
                          todayEntry.status != AttendanceStatus.remote,
                      onSelected:
                          isTodayWorkingDay ? (_) => onOtherCheckIn() : null,
                    ),
                  ],
                ),
                if (!isTodayWorkingDay) ...[
                  const SizedBox(height: 9),
                  Text(
                    'Check-ins are unavailable outside your workweek.',
                    style: TextStyle(color: _mutedFor(context), fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const _PrivacyNote(),
      ],
    );
  }
}

class _QuarterPicker extends StatelessWidget {
  const _QuarterPicker({required this.date, required this.onChanged});

  final DateTime date;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.calendar_today_rounded, size: 17, color: _teal),
          const SizedBox(width: 8),
          Text(quarterLabel(date),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: _inkFor(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            tooltip: 'Previous quarter',
            onPressed: () => onChanged(DateTime(date.year, date.month - 3)),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            tooltip: 'Next quarter',
            onPressed: () => onChanged(DateTime(date.year, date.month + 3)),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      );
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.summary, required this.attendancePercent});

  final QuarterSummary summary;
  final int attendancePercent;

  @override
  Widget build(BuildContext context) {
    final achieved = summary.remainingOfficeDays == 0;
    final status = achieved
        ? 'Goal achieved'
        : summary.isAchievable
            ? 'You’re on your way'
            : 'Goal is at risk';
    return Card(
      color: _ink,
      child: Padding(
        padding: const EdgeInsets.all(21),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('ATTENDANCE RATE',
                      style: TextStyle(
                          color: Color(0xFFB7C9CE),
                          fontSize: 11,
                          letterSpacing: 1.3,
                          fontWeight: FontWeight.w700)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('$attendancePercent%',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 17),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${summary.officeDays}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 46,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -2)),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5, left: 7),
                  child: Text('of ${summary.targetDays} office days',
                      style: const TextStyle(
                          color: Color(0xFFCBD6D9), fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: attendancePercent / 100,
                backgroundColor: Colors.white.withValues(alpha: .15),
                valueColor: const AlwaysStoppedAnimation(Color(0xFF6DD2BD)),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 6,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      achieved
                          ? Icons.check_circle_rounded
                          : summary.isAchievable
                              ? Icons.trending_up_rounded
                              : Icons.info_rounded,
                      size: 17,
                      color: const Color(0xFF8DE0CC),
                    ),
                    const SizedBox(width: 7),
                    Text(status,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                  ],
                ),
                Text('${summary.eligibleDays} eligible days',
                    style: const TextStyle(
                        color: Color(0xFFCBD6D9), fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 19),
              const SizedBox(height: 12),
              Text(value,
                  style: TextStyle(
                      color: _inkFor(context),
                      fontSize: 27,
                      fontWeight: FontWeight.w800,
                      height: 1)),
              const SizedBox(height: 6),
              Text(label,
                  style: TextStyle(
                      color: _inkFor(context),
                      fontWeight: FontWeight.w600,
                      fontSize: 12)),
              const SizedBox(height: 3),
              Text(detail,
                  style: TextStyle(color: _mutedFor(context), fontSize: 10)),
            ],
          ),
        ),
      );
}

class _CalendarPage extends StatefulWidget {
  const _CalendarPage({
    required this.month,
    required this.entries,
    required this.workdays,
    required this.onMonthChanged,
    required this.onEdit,
    required this.onApplyBulk,
  });

  final DateTime month;
  final Map<String, AttendanceEntry> entries;
  final Set<int> workdays;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<DateTime> onEdit;
  final Future<void> Function(List<AttendanceEntry>) onApplyBulk;

  @override
  State<_CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<_CalendarPage> {
  final Set<DateTime> _selectedDates = {};
  bool _isSelecting = false;

  DateTime get month => widget.month;
  Map<String, AttendanceEntry> get entries => widget.entries;
  Set<int> get workdays => widget.workdays;
  ValueChanged<DateTime> get onMonthChanged => widget.onMonthChanged;
  ValueChanged<DateTime> get onEdit => widget.onEdit;

  void _toggleDateSelection(DateTime date) {
    setState(() {
      _isSelecting = true;
      if (!_selectedDates.add(date)) {
        _selectedDates.remove(date);
      }
    });
  }

  Future<void> _applyBulkStatus() async {
    final dates = _selectedDates.toList()..sort();
    if (dates.isEmpty) return;

    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final hasFutureDates = dates.any((date) => date.isAfter(todayDate));
    final allWorkdays = dates.every((date) => workdays.contains(date.weekday));
    final statuses = <AttendanceStatus>[
      if (allWorkdays && !hasFutureDates) AttendanceStatus.office,
      if (allWorkdays) AttendanceStatus.remote,
      AttendanceStatus.pto,
      AttendanceStatus.holiday,
      if (allWorkdays && !hasFutureDates) AttendanceStatus.sick,
    ];
    final selectedStatus = await showModalBottomSheet<AttendanceStatus>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _BulkStatusSheet(
        dayCount: dates.length,
        statuses: statuses,
        hasFutureDates: hasFutureDates,
        hasNonWorkdays: !allWorkdays,
      ),
    );
    if (selectedStatus == null || !mounted) return;

    final conflicts = dates
        .map((date) => entries[attendanceDateKey(date)])
        .where((entry) => entry != null && entry.status != selectedStatus)
        .length;
    if (conflicts > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace existing statuses?'),
          content: Text(
            '$conflicts selected ${conflicts == 1 ? 'day already has' : 'days already have'} a different status. Replace them with ${selectedStatus.label}?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    await widget.onApplyBulk([
      for (final date in dates)
        AttendanceEntry(date: date, status: selectedStatus),
    ]);
    if (mounted) {
      setState(() {
        _selectedDates.clear();
        _isSelecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final offset = first.weekday - 1;
    final count = ((offset + days + 6) ~/ 7) * 7;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
      children: [
        Text('Your calendar',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: _inkFor(context), fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
            'Use the checklist button to select multiple days and set one status.',
            style: TextStyle(color: _mutedFor(context))),
        const SizedBox(height: 21),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous month',
                      onPressed: () =>
                          onMonthChanged(DateTime(month.year, month.month - 1)),
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    Expanded(
                      child: Text(_monthLabel(month),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: _inkFor(context),
                              fontSize: 16,
                              fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      tooltip: 'Next month',
                      onPressed: () =>
                          onMonthChanged(DateTime(month.year, month.month + 1)),
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                    IconButton(
                      tooltip: _isSelecting
                          ? 'Done selecting days'
                          : 'Select multiple days',
                      onPressed: () => setState(() {
                        _isSelecting = !_isSelecting;
                        if (!_isSelecting) _selectedDates.clear();
                      }),
                      icon: Icon(
                        _isSelecting
                            ? Icons.close_rounded
                            : Icons.checklist_rounded,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final day in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                      Expanded(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 9),
                            child: Text(day,
                                style: TextStyle(
                                    color: _mutedFor(context),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                  ],
                ),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: count,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    mainAxisSpacing: 3,
                    crossAxisSpacing: 3,
                    childAspectRatio: .92,
                  ),
                  itemBuilder: (context, index) {
                    final dayNumber = index - offset + 1;
                    if (dayNumber < 1 || dayNumber > days) {
                      return const SizedBox.shrink();
                    }
                    final date = DateTime(month.year, month.month, dayNumber);
                    final status = entries[attendanceDateKey(date)]?.status;
                    final isWorkingDay = workdays.contains(date.weekday);
                    final isToday = _sameDate(date, DateTime.now());
                    final isSelected = _selectedDates.contains(date);
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: isWorkingDay
                          ? () {
                              if (_isSelecting) {
                                _toggleDateSelection(date);
                              } else {
                                onEdit(date);
                              }
                            }
                          : null,
                      onLongPress: isWorkingDay
                          ? () => _toggleDateSelection(date)
                          : null,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? _teal.withValues(alpha: .14)
                                  : !isWorkingDay
                                      ? const Color(0xFFE9EDEC)
                                      : status == null
                                          ? Colors.transparent
                                          : _statusColor(status)
                                              .withValues(alpha: .14),
                              borderRadius: BorderRadius.circular(12),
                              border: isWorkingDay && (isSelected || isToday)
                                  ? Border.all(color: _teal, width: 1.4)
                                  : null,
                            ),
                            child: Text('$dayNumber',
                                style: TextStyle(
                                    color: isWorkingDay || isSelected
                                        ? _inkFor(context)
                                        : const Color(0xFFA6B0B3),
                                    fontWeight: isToday || status != null
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    fontSize: 12)),
                          ),
                          const SizedBox(height: 3),
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: status == null
                                  ? Colors.transparent
                                  : isWorkingDay
                                      ? _statusColor(status)
                                      : const Color(0xFFA6B0B3),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        if (_selectedDates.isNotEmpty) ...[
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  Text('${_selectedDates.length} days selected',
                      style: TextStyle(
                          color: _inkFor(context),
                          fontWeight: FontWeight.w700)),
                  TextButton(
                    onPressed: () => setState(_selectedDates.clear),
                    child: const Text('Clear'),
                  ),
                  FilledButton.icon(
                    onPressed: _applyBulkStatus,
                    icon: const Icon(Icons.edit_calendar_rounded),
                    label: const Text('Set status'),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Text('Status guide',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: _inkFor(context), fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 10,
          children: [
            ...AttendanceStatus.values
                .map((status) => _LegendItem(status: status)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircleAvatar(
                  radius: 4,
                  backgroundColor: Color(0xFFA6B0B3),
                ),
                const SizedBox(width: 6),
                Text(
                  'Non-working day',
                  style: TextStyle(color: _mutedFor(context), fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 18),
        const _PrivacyNote(),
      ],
    );
  }
}

class _InsightsPage extends StatelessWidget {
  const _InsightsPage({required this.summary, required this.quarter});

  final QuarterSummary summary;
  final DateTime quarter;

  @override
  Widget build(BuildContext context) {
    final rate = summary.attendanceRatePercent;
    final achieved = summary.remainingOfficeDays == 0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
      children: [
        Text('A clearer picture',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: _inkFor(context), fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('${quarterLabel(quarter)} · your attendance insights',
            style: TextStyle(color: _mutedFor(context))),
        const SizedBox(height: 20),
        _InsightTile(
          icon: Icons.percent_rounded,
          title: 'Attendance rate',
          value: '$rate%',
          description: summary.eligibleDays == 0
              ? 'No eligible workdays are configured for this quarter.'
              : '${summary.officeDays} of ${summary.eligibleDays} eligible workdays this quarter.',
        ),
        const SizedBox(height: 12),
        _InsightTile(
          icon: Icons.track_changes_rounded,
          title: 'Target progress',
          value: '${(summary.targetProgress * 100).round()}%',
          description:
              '${summary.officeDays} confirmed of ${summary.targetDays} office days needed.',
        ),
        const SizedBox(height: 12),
        _InsightTile(
          icon: summary.isAchievable
              ? Icons.event_available_rounded
              : Icons.warning_amber_rounded,
          title: achieved
              ? 'Quarterly target achieved'
              : summary.isAchievable
                  ? 'Your goal is achievable'
                  : 'Your goal may be out of reach',
          value: '${summary.remainingOfficeDays} more',
          description: achieved
              ? 'You have met your office-day target for this quarter.'
              : '${summary.suitableFutureDays} suitable workdays remain in this quarter.',
        ),
        const SizedBox(height: 17),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_outline_rounded, color: _teal),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    achieved
                        ? 'Nice work. Your quarterly office target is in the books.'
                        : summary.isAchievable
                            ? 'Spread your remaining ${summary.remainingOfficeDays} office ${summary.remainingOfficeDays == 1 ? 'day' : 'days'} across the quarter to keep your schedule flexible.'
                            : 'Your current schedule has fewer suitable days than needed. Review your workweek and planned time off.',
                    style: TextStyle(
                        color: _inkFor(context), height: 1.45, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InsightTile extends StatelessWidget {
  const _InsightTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String value;
  final String description;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                    color: const Color(0xFFE7F3F0),
                    borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: _teal, size: 21),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: _inkFor(context),
                            fontWeight: FontWeight.w700,
                            fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(description,
                        style: TextStyle(
                            color: _mutedFor(context),
                            height: 1.3,
                            fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(value,
                  style: const TextStyle(
                      color: _teal, fontWeight: FontWeight.w800, fontSize: 16)),
            ],
          ),
        ),
      );
}

class _HistoryPage extends StatelessWidget {
  const _HistoryPage({required this.entries, required this.onEdit});

  final Map<String, AttendanceEntry> entries;
  final ValueChanged<DateTime> onEdit;

  @override
  Widget build(BuildContext context) {
    final records = entries.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
      children: [
        Text('Your history',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: _inkFor(context), fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('Your attendance, saved privately on this device.',
            style: TextStyle(color: _mutedFor(context))),
        const SizedBox(height: 19),
        if (records.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                children: [
                  const Icon(Icons.event_note_rounded, size: 34, color: _teal),
                  const SizedBox(height: 12),
                  Text('Your story starts here',
                      style: TextStyle(
                          color: _inkFor(context),
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 5),
                  Text('Mark a day to see it in your history.',
                      style: TextStyle(color: _mutedFor(context))),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: () => onEdit(DateTime.now()),
                    child: const Text('Mark today'),
                  ),
                ],
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var index = 0; index < records.length; index++) ...[
                  ListTile(
                    onTap: () => onEdit(records[index].date),
                    leading: _StatusDot(status: records[index].status),
                    title: Text(records[index].status.label,
                        style: TextStyle(
                            color: _inkFor(context),
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                    subtitle: Text(_dateLabel(records[index].date),
                        style:
                            TextStyle(color: _mutedFor(context), fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
                  if (index < records.length - 1)
                    const Divider(height: 1, indent: 62),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _StatusSheet extends StatelessWidget {
  const _StatusSheet({
    required this.date,
    required this.current,
    required this.isFuture,
    required this.isWorkingDay,
  });

  final DateTime date;
  final AttendanceStatus? current;
  final bool isFuture;
  final bool isWorkingDay;

  @override
  Widget build(BuildContext context) {
    final statuses = isFuture
        ? <AttendanceStatus>[
            AttendanceStatus.remote,
            AttendanceStatus.pto,
            AttendanceStatus.holiday,
          ]
        : AttendanceStatus.values.toList();
    if (!isWorkingDay) {
      statuses.removeWhere((status) =>
          status == AttendanceStatus.office ||
          status == AttendanceStatus.remote);
    }
    return SafeArea(
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(26),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(child: _SheetHandle()),
              const SizedBox(height: 21),
              Text(isFuture ? 'Plan a day' : 'Mark your day',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: _inkFor(context), fontWeight: FontWeight.w800)),
              const SizedBox(height: 5),
              Text(_dateLabel(date),
                  style: TextStyle(color: _mutedFor(context))),
              if (!isWorkingDay) ...[
                const SizedBox(height: 9),
                Text(
                  'This date is outside your workweek. In Office and Remote are unavailable.',
                  style: TextStyle(
                    color: _mutedFor(context),
                    height: 1.4,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 15),
              for (final status in statuses)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _StatusDot(status: status),
                  title: Text(status.label,
                      style: TextStyle(
                          color: _inkFor(context),
                          fontWeight: FontWeight.w600)),
                  trailing: current == status
                      ? const Icon(Icons.check_circle_rounded, color: _teal)
                      : const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop<Object>(context, status),
                ),
              if (current != null)
                TextButton.icon(
                  onPressed: () => Navigator.pop<Object>(context, 'clear'),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Remove this entry'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OtherCheckInSheet extends StatelessWidget {
  const _OtherCheckInSheet({required this.current});

  final AttendanceStatus? current;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: _SheetHandle()),
                const SizedBox(height: 21),
                Text('Other status',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: _inkFor(context), fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                Text('Choose the option that best describes today.',
                    style: TextStyle(color: _mutedFor(context))),
                const SizedBox(height: 12),
                for (final status in const [
                  AttendanceStatus.pto,
                  AttendanceStatus.holiday,
                  AttendanceStatus.sick,
                ])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _StatusDot(status: status),
                    title: Text(status.label,
                        style: TextStyle(
                            color: _inkFor(context),
                            fontWeight: FontWeight.w600)),
                    trailing: current == status
                        ? const Icon(Icons.check_circle_rounded, color: _teal)
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pop(context, status),
                  ),
              ],
            ),
          ),
        ),
      );
}

class _BulkStatusSheet extends StatelessWidget {
  const _BulkStatusSheet({
    required this.dayCount,
    required this.statuses,
    required this.hasFutureDates,
    required this.hasNonWorkdays,
  });

  final int dayCount;
  final List<AttendanceStatus> statuses;
  final bool hasFutureDates;
  final bool hasNonWorkdays;

  @override
  Widget build(BuildContext context) {
    final message = hasNonWorkdays
        ? 'Remove non-working days to apply In Office or Remote.'
        : hasFutureDates
            ? 'Future days can be planned as Remote, PTO, or a holiday.'
            : null;

    return SafeArea(
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(26),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(child: _SheetHandle()),
              const SizedBox(height: 21),
              Text('Set status for $dayCount days',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: _inkFor(context), fontWeight: FontWeight.w800)),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(message,
                    style: TextStyle(color: _mutedFor(context), fontSize: 12)),
              ],
              const SizedBox(height: 12),
              for (final status in statuses)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _StatusDot(status: status),
                  title: Text(status.label,
                      style: TextStyle(
                          color: _inkFor(context),
                          fontWeight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop(context, status),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.status});

  final AttendanceStatus status;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: _statusColor(status), shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(status.shortLabel,
              style: TextStyle(color: _mutedFor(context), fontSize: 11)),
        ],
      );
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final AttendanceStatus? status;

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: status == null
              ? const Color(0xFFF0F3F2)
              : _statusColor(status!).withValues(alpha: .13),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Icon(
          status == null ? Icons.add_rounded : _statusIcon(status!),
          color: status == null ? _teal : _statusColor(status!),
          size: 19,
        ),
      );
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline_rounded, size: 13, color: _mutedFor(context)),
          const SizedBox(width: 6),
          Text('Your attendance stays on this device.',
              style: TextStyle(color: _mutedFor(context), fontSize: 11)),
        ],
      );
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFD5DEDB),
          borderRadius: BorderRadius.circular(4),
        ),
      );
}

Color _statusColor(AttendanceStatus status) => switch (status) {
      AttendanceStatus.office => const Color(0xFF18836D),
      AttendanceStatus.remote => const Color(0xFF3984C5),
      AttendanceStatus.pto => const Color(0xFFB45F7A),
      AttendanceStatus.holiday => const Color(0xFFDB9C3D),
      AttendanceStatus.sick => const Color(0xFF8571B5),
    };

IconData _statusIcon(AttendanceStatus status) => switch (status) {
      AttendanceStatus.office => Icons.apartment_rounded,
      AttendanceStatus.remote => Icons.home_work_rounded,
      AttendanceStatus.pto => Icons.beach_access_rounded,
      AttendanceStatus.holiday => Icons.celebration_rounded,
      AttendanceStatus.sick => Icons.healing_rounded,
    };

String _dateLabel(DateTime date) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}, ${date.year}';
}

String _monthLabel(DateTime date) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${months[date.month - 1]} ${date.year}';
}

bool _sameDate(DateTime first, DateTime second) =>
    first.year == second.year &&
    first.month == second.month &&
    first.day == second.day;

bool _isToday(DateTime date) => _sameDate(date, DateTime.now());
