import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tz_data;

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _expireChannelId = 'expire_channel';
  static const _expireNotificationId = 1001;

  static Future<void> init() async {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(await _localTimeZoneName()));

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
        _expireChannelId,
        '服务到期提醒',
        description: '服务时长即将到期或已到期的提醒',
        importance: Importance.high,
      ));
    }
  }

  static Future<String> _localTimeZoneName() async {
    return DateTime.now().timeZoneName.isNotEmpty ? tz.local.name : 'UTC';
  }

  static Future<bool> requestPermission() async {
    if (Platform.isIOS) {
      final result = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return result ?? false;
    }
    if (Platform.isAndroid) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  static Future<void> scheduleExpireReminder({
    required DateTime expireTime,
    Duration before = const Duration(hours: 1),
  }) async {
    await _plugin.cancel(_expireNotificationId);

    final fireTime = expireTime.subtract(before);
    if (fireTime.isBefore(DateTime.now())) return;

    await _plugin.zonedSchedule(
      _expireNotificationId,
      '服务即将到期',
      '您的服务将于 ${_formatTime(expireTime)} 到期，请及时续费。',
      tz.TZDateTime.from(fireTime, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _expireChannelId,
          '服务到期提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  static Future<void> showExpiredNow() async {
    await _plugin.show(
      _expireNotificationId + 1,
      '服务已到期',
      '您的服务时长已用完，点击立即充值。',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _expireChannelId,
          '服务到期提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  static String _formatTime(DateTime t) =>
      '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}