import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'radio_config.dart';
import 'services/radio_audio_handler.dart';
import 'screens/now_playing_screen.dart';

late AudioHandler _audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Registra l'handler presso il sistema operativo: da questo momento
  // lock screen, notifica, Android Auto e CarPlay sono tutti alimentati
  // dallo stesso RadioAudioHandler.
  _audioHandler = await AudioService.init(
    builder: () => RadioAudioHandler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: '${RadioConfig.androidApplicationId}.channel.audio',
      androidNotificationChannelName: RadioConfig.stationName,
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: false,
    ),
  );

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
      home: NowPlayingScreen(audioHandler: _audioHandler),
    );
  }
}
