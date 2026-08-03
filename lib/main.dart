import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'radio_config.dart';
import 'services/radio_audio_handler.dart';
import 'services/alarm_service.dart';
import 'screens/now_playing_screen.dart';

late AudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Registra l'handler presso il sistema operativo: da questo momento
  // lock screen, notifica, Android Auto e CarPlay sono tutti alimentati
  // dallo stesso RadioAudioHandler.
  audioHandler = await AudioService.init(
    builder: () => RadioAudioHandler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: '${RadioConfig.androidApplicationId}.channel.audio',
      androidNotificationChannelName: RadioConfig.stationName,
      // Nota: androidNotificationOngoing:true richiederebbe
      // androidStopForegroundOnPause:true (vincolo del pacchetto
      // audio_service). Per una radio live vogliamo che il servizio in
      // background resti vivo anche in pausa, quindi teniamo
      // androidStopForegroundOnPause:false e disattiviamo "ongoing".
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
    ),
  );

  await initAlarmSystem();
  // Se l'utente tocca la notifica della sveglia (unico modo su iOS per
  // avviare la radio, vedi alarm_service.dart), la riproduzione parte da qui.
  onAlarmNotificationTapped = () => audioHandler.play();

  runApp(const SaurosoftRadioApp());
}

class SaurosoftRadioApp extends StatelessWidget {
  const SaurosoftRadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: RadioConfig.stationName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: NowPlayingScreen(audioHandler: audioHandler),
    );
  }
}
