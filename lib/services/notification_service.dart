import 'dart:typed_data';
import 'dart:ui';
import 'dart:math';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:permission_handler/permission_handler.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/medication.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static final FlutterLocalNotificationsPlugin _notifications =
  FlutterLocalNotificationsPlugin();

  static final AudioPlayer _audioPlayer = AudioPlayer();
  static bool _isAlarmPlaying = false;
  static int? _currentAlarmId;

  // Alarm sounds from the Alarms class
  static const List<String> _alarmSounds = [
    "assets/audios/retro-audio-logo-94648.mp3",
    "assets/audios/art-of-samples-buzz-120-bpm-audio-logo-245396.mp3",
  ];

  // Initialize notifications and alarm manager
  static Future<bool> initialize() async {
    // Initialize timezone
    tz.initializeTimeZones();

    // Initialize Android Alarm Manager
    await AndroidAlarmManager.initialize();

    // Request permissions first
    final permissionGranted = await _requestAllPermissions();

    const AndroidInitializationSettings androidSettings =
    AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosSettings =
    DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create notification channel with high importance for Android
    await _createNotificationChannel();

    return permissionGranted;
  }

  static Future<bool> _requestAllPermissions() async {
    // Request notification permission
    final notificationStatus = await Permission.notification.request();

    // Request phone permission for ringtone access
    final phoneStatus = await Permission.phone.request();

    // Request exact alarm permission for Android 12+
    if (await Permission.scheduleExactAlarm.isDenied) {
      await Permission.scheduleExactAlarm.request();
    }

    // Request system alert window permission for alarm overlay
    final systemAlertWindowStatus = await Permission.systemAlertWindow.request();

    // Additional permissions for Android
    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
    _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      await androidImplementation.requestExactAlarmsPermission();
      await androidImplementation.requestNotificationsPermission();
    }

    // iOS permissions
    final IOSFlutterLocalNotificationsPlugin? iosImplementation =
    _notifications.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();

    if (iosImplementation != null) {
      await iosImplementation.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
        critical: true, // For critical alerts
      );
    }

    return notificationStatus.isGranted;
  }

  static Future<void> _createNotificationChannel() async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'medication_reminders_high',
      'Medication Reminders',
      description: 'High priority notifications for medication reminders',
      importance: Importance.max,
      enableVibration: true,
      enableLights: true,
      ledColor: Color.fromARGB(255, 255, 0, 0),
      showBadge: true,
      playSound: false, // We'll handle sound with AudioPlayer
    );

    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
    _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      await androidImplementation.createNotificationChannel(channel);
    }
  }

  static void _onNotificationTapped(NotificationResponse response) {
    print('Notification tapped: ${response.payload}');

    // Stop any playing alarm when notification is tapped
    _stopAlarm();

    // Handle different actions
    switch (response.actionId) {
      case 'mark_taken':
        _handleMarkAsTaken(response.payload);
        break;
      case 'snooze':
        _handleSnooze(response.payload);
        break;
      default:
      // Handle default tap - stop alarm
        break;
    }
  }

  static void _handleMarkAsTaken(String? payload) {
    if (payload != null) {
      print('Marking medication as taken: $payload');
      _stopAlarm();
      // Cancel the alarm for this medication time
      final parts = payload.split(':');
      if (parts.length == 2) {
        final medicationId = int.tryParse(parts[0]);
        final reminderIndex = int.tryParse(parts[1]);
        if (medicationId != null && reminderIndex != null) {
          final alarmId = _generateAlarmId(medicationId, reminderIndex);
          AndroidAlarmManager.cancel(alarmId);
        }
      }
    }
  }

  static void _handleSnooze(String? payload) {
    if (payload != null) {
      print('Snoozing medication: $payload');
      _stopAlarm();
      final parts = payload.split(':');
      if (parts.length == 2) {
        final medicationId = int.tryParse(parts[0]);
        final reminderIndex = int.tryParse(parts[1]);
        if (medicationId != null && reminderIndex != null) {
          final notificationId = _generateNotificationId(medicationId, reminderIndex);
          snoozeNotification(
              notificationId,
              'Medication Reminder (Snoozed)',
              'Time to take your medication',
              medicationId,
              reminderIndex);
        }
      }
    }
  }

  // Callback function for AndroidAlarmManager - must be static and top-level
  @pragma('vm:entry-point')
  static void alarmCallback() {
    _playAlarmSound();
  }

  // Play alarm sound continuously
  static Future<void> _playAlarmSound() async {
    if (_isAlarmPlaying) return;

    _isAlarmPlaying = true;

    // Select random alarm sound
    final random = Random();
    final selectedAlarm = _alarmSounds[random.nextInt(_alarmSounds.length)];

    try {
      // Set audio player mode for alarm
      await _audioPlayer.setPlayerMode(PlayerMode.mediaPlayer);
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.setVolume(1.0); // Maximum volume

      // Play the alarm sound in loop
      await _audioPlayer.play(AssetSource(selectedAlarm));

      print('Playing alarm: $selectedAlarm');

      // Stop alarm after 1 minute if not stopped manually
      Future.delayed(const Duration(minutes: 1), () {
        if (_isAlarmPlaying) {
          _stopAlarm();
        }
      });
    } catch (e) {
      print('Error playing alarm: $e');
      _isAlarmPlaying = false;
    }
  }

  // Stop alarm sound
  static Future<void> _stopAlarm() async {
    if (!_isAlarmPlaying) return;

    try {
      await _audioPlayer.stop();
      _isAlarmPlaying = false;
      print('Alarm stopped');
    } catch (e) {
      print('Error stopping alarm: $e');
    }
  }

  // Schedule notifications for a medication with alarm
  static Future<void> scheduleMedicationReminders(Medication medication) async {
    if (medication.id == null) return;

    // Cancel existing notifications and alarms for this medication
    await cancelMedicationReminders(medication.id!);

    for (int i = 0; i < medication.reminderTimes.length; i++) {
      final timeString = medication.reminderTimes[i];
      final dose = i < medication.doses.length ? medication.doses[i] : '1 dose';

      // Parse time string (assuming format "HH:mm")
      final timeParts = timeString.split(':');
      if (timeParts.length != 2) continue;

      final hour = int.tryParse(timeParts[0]);
      final minute = int.tryParse(timeParts[1]);

      if (hour == null || minute == null) continue;

      // Create unique notification and alarm IDs
      final notificationId = _generateNotificationId(medication.id!, i);
      final alarmId = _generateAlarmId(medication.id!, i);

      // Schedule daily recurring notification
      await _scheduleRepeatingNotification(
        id: notificationId,
        title: '💊 Medication Time!',
        body: 'Take ${medication.name} (${medication.unit}) - $dose',
        hour: hour,
        minute: minute,
        payload: '${medication.id}:$i',
      );

      // Schedule daily recurring alarm
      await _scheduleRepeatingAlarm(alarmId, hour, minute);
    }
  }

  static Future<void> _scheduleRepeatingNotification({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
    String? payload,
  }) async {
    // Android notification without sound (handled by AudioPlayer)
    AndroidNotificationDetails androidDetails =
    AndroidNotificationDetails(
      'medication_reminders_high',
      'Medication Reminders',
      channelDescription: 'High priority notifications for medication reminders',
      importance: Importance.max,
      priority: Priority.high,

      // No sound - handled by our custom alarm
      playSound: false,

      // Vibration settings
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),

      // Visual settings
      enableLights: true,
      ledColor: const Color.fromARGB(255, 255, 0, 0),
      ledOnMs: 1000,
      ledOffMs: 500,

      // Behavior settings
      autoCancel: false,
      ongoing: true, // Keep notification persistent
      showWhen: true,
      onlyAlertOnce: false,

      // Full screen intent for critical alerts
      fullScreenIntent: true,

      // Category for better handling
      category: AndroidNotificationCategory.alarm,

      // Visibility
      visibility: NotificationVisibility.public,

      // Actions
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          'mark_taken',
          '✅ Mark as Taken',
          showsUserInterface: true,
          allowGeneratedReplies: false,
          contextual: true,
        ),
        AndroidNotificationAction(
          'snooze',
          '⏰ Snooze 10 min',
          showsUserInterface: false,
          allowGeneratedReplies: false,
          contextual: true,
        ),
      ],

      // Style
      styleInformation: const BigTextStyleInformation(
        'Tap "Mark as Taken" when you\'ve taken your medication, or "Snooze" to be reminded again in 10 minutes.',
        htmlFormatBigText: true,
        contentTitle: '💊 Medication Reminder',
        htmlFormatContentTitle: true,
        summaryText: 'DoziYangu App',
        htmlFormatSummaryText: true,
      ),
    );

    // iOS notification
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: false, // Custom sound handled by AudioPlayer
      badgeNumber: 1,
      categoryIdentifier: 'MEDICATION_REMINDER',
      threadIdentifier: 'medication_reminders',
    );

    NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Calculate next occurrence
    final now = DateTime.now();
    var scheduledDate = DateTime(now.year, now.month, now.day, hour, minute);

    // If the time has passed today, schedule for tomorrow
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    final tzScheduledDate = tz.TZDateTime.from(scheduledDate, tz.local);

    await _notifications.zonedSchedule(
      id,
      title,
      body,
      tzScheduledDate,
      notificationDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
      UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time, // Repeat daily
      payload: payload,
    );
  }

  // Schedule repeating alarm using AndroidAlarmManager
  static Future<void> _scheduleRepeatingAlarm(int alarmId, int hour, int minute) async {
    // Calculate next occurrence
    final now = DateTime.now();
    var alarmTime = DateTime(now.year, now.month, now.day, hour, minute);

    // If the time has passed today, schedule for tomorrow
    if (alarmTime.isBefore(now)) {
      alarmTime = alarmTime.add(const Duration(days: 1));
    }

    // Schedule daily recurring alarm
    await AndroidAlarmManager.periodic(
      const Duration(days: 1), // Repeat every day
      alarmId,
      alarmCallback,
      startAt: alarmTime,
      exact: true,
      wakeup: true,
      allowWhileIdle: true,
    );

    print('Scheduled alarm $alarmId for ${alarmTime.toString()}');
  }

  // Enhanced snooze with alarm
  static Future<void> snoozeNotification(
      int notificationId, String title, String body, int medicationId, int reminderIndex) async {
    AndroidNotificationDetails androidDetails =
    AndroidNotificationDetails(
      'medication_reminders_high',
      'Medication Reminders',
      channelDescription: 'High priority notifications for medication reminders',
      importance: Importance.max,
      priority: Priority.high,
      playSound: false,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
      autoCancel: false,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: false,
    );

    NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final snoozeTime = DateTime.now().add(const Duration(minutes: 10));
    final tzSnoozeTime = tz.TZDateTime.from(snoozeTime, tz.local);

    // Schedule snoozed notification
    await _notifications.zonedSchedule(
      notificationId + 1000, // Different ID for snoozed notification
      '⏰ $title',
      body,
      tzSnoozeTime,
      notificationDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
      UILocalNotificationDateInterpretation.absoluteTime,
    );

    // Schedule snoozed alarm
    final snoozeAlarmId = _generateAlarmId(medicationId, reminderIndex) + 1000;
    await AndroidAlarmManager.oneShot(
      const Duration(minutes: 10),
      snoozeAlarmId,
      alarmCallback,
      exact: true,
      wakeup: true,
      allowWhileIdle: true,
    );
  }

  // Show immediate test notification with alarm
  static Future<void> showTestNotification() async {
    AndroidNotificationDetails androidDetails =
    AndroidNotificationDetails(
      'medication_reminders_high',
      'Medication Reminders',
      channelDescription: 'Test notification',
      importance: Importance.max,
      priority: Priority.high,
      playSound: false,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
      fullScreenIntent: true,
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: false,
    );

    NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(
      999,
      '💊 Test Medication Reminder',
      'This is how your medication reminders will appear. The alarm will play for 1 minute.',
      notificationDetails,
    );

    // Play test alarm
    _playAlarmSound();
  }

  // Cancel all notifications and alarms for a specific medication
  static Future<void> cancelMedicationReminders(int medicationId) async {
    for (int i = 0; i < 10; i++) {
      final notificationId = _generateNotificationId(medicationId, i);
      final alarmId = _generateAlarmId(medicationId, i);

      await _notifications.cancel(notificationId);
      await AndroidAlarmManager.cancel(alarmId);
    }
  }

  // Cancel all notifications and alarms
  static Future<void> cancelAllNotifications() async {
    await _notifications.cancelAll();
    // Note: AndroidAlarmManager doesn't have cancelAll,
    // you'll need to track and cancel individual alarms
    _stopAlarm();
  }

  // Generate unique notification ID
  static int _generateNotificationId(int medicationId, int reminderIndex) {
    return medicationId * 100 + reminderIndex;
  }

  // Generate unique alarm ID
  static int _generateAlarmId(int medicationId, int reminderIndex) {
    return medicationId * 200 + reminderIndex; // Different range from notifications
  }

  // Check if notifications are enabled
  static Future<bool> areNotificationsEnabled() async {
    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
    _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      return await androidImplementation.areNotificationsEnabled() ?? false;
    }
    return true; // Assume enabled for iOS
  }

  // Get pending notifications
  static Future<List<PendingNotificationRequest>> getPendingNotifications() async {
    return await _notifications.pendingNotificationRequests();
  }

  // Check all permissions status
  static Future<Map<String, bool>> checkAllPermissions() async {
    return {
      'notification': await Permission.notification.isGranted,
      'phone': await Permission.phone.isGranted,
      'exactAlarm': await Permission.scheduleExactAlarm.isGranted,
      'systemAlertWindow': await Permission.systemAlertWindow.isGranted,
    };
  }

  // Stop any currently playing alarm (public method)
  static Future<void> stopCurrentAlarm() async {
    await _stopAlarm();
  }

  // Check if alarm is currently playing
  static bool get isAlarmPlaying => _isAlarmPlaying;
}