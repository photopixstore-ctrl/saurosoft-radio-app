import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../radio_config.dart';

const int _sveglioNotificationId = 4201;

final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

/// Va chiamata una volta all'avvio dell'app (vedi main.dart).
///
/// Implementazione volutamente semplice e affidabile su entrambe le
/// piattaforme: una notifica programmata all'orario scelto che, se
/// toccata, apre l'app e avvia la riproduzione. Niente avvio automatico
/// "silenzioso" ad app chiusa (quella strada, possibile solo su Android
/// con meccanismi di sistema piu' delicati, e' stata scartata per questa
/// versione a favore di qualcosa di semplice e affidabile su entrambe
/// le piattaforme).
Future<void> initAlarmSystem() async {
  tzdata.initializeTimeZones();
  // App pensata per il pubblico italiano: fuso orario fisso Europe/Rome
  // (gestisce gia' da solo il passaggio ora legale/solare).
  tz.setLocalLocation(tz.getLocation('Europe/Rome'));

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestSoundPermission: true,
    requestBadgePermission: true,
  );
  await _notifications.initialize(
    const InitializationSettings(android: androidInit, iOS: iosInit),
    onDidReceiveNotificationResponse: (response) {
      // L'utente ha toccato la notifica: avvia la riproduzione.
      onAlarmNotificationTapped?.call();
    },
  );
}

/// Impostata da main.dart, chiamata quando l'utente tocca la notifica sveglia.
void Function()? onAlarmNotificationTapped;

class AlarmService {
  /// Programma una notifica al prossimo orario hh:mm (oggi se non e' gia'
  /// passato, altrimenti domani). Toccandola si apre l'app e parte la radio.
  static Future<void> programma(int hour, int minute) async {
    final now = DateTime.now();
    var orario = DateTime(now.year, now.month, now.day, hour, minute);
    if (!orario.isAfter(now)) {
      orario = orario.add(const Duration(days: 1));
    }

    final scheduled = tz.TZDateTime.from(orario, tz.local);
    await _notifications.zonedSchedule(
      _sveglioNotificationId,
      RadioConfig.stationName,
      'Tocca per avviare la radio',
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'saurosoft_alarm_channel',
          'Sveglia',
          channelDescription: 'Notifica per la sveglia radio',
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true,
        ),
        iOS: DarwinNotificationDetails(sound: 'default', presentAlert: true, presentSound: true),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  static Future<void> annulla() async {
    await _notifications.cancel(_sveglioNotificationId);
  }
}
