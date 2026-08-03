import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../radio_config.dart';

class NowPlayingScreen extends StatelessWidget {
  final AudioHandler audioHandler;

  const NowPlayingScreen({super.key, required this.audioHandler});

  /// Sfondo stagionale: stesso concetto gia' presente nell'app Android
  /// (cambia in base al mese corrente, es. neve in inverno, foglie in autunno).
  String _seasonalBackground() {
    final month = DateTime.now().month;
    if (month == 12 || month <= 2) return 'assets/images/bg_winter.jpg';
    if (month >= 3 && month <= 5) return 'assets/images/bg_spring.jpg';
    if (month >= 6 && month <= 8) return 'assets/images/bg_summer.jpg';
    return 'assets/images/bg_autumn.jpg';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(_seasonalBackground(), fit: BoxFit.cover),
          Container(color: Colors.black.withOpacity(0.45)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: StreamBuilder<MediaItem?>(
                      stream: audioHandler.mediaItem,
                      builder: (context, snapshot) {
                        final artUri = snapshot.data?.artUri?.toString() ??
                            RadioConfig.logoAssetPath;
                        if (artUri.startsWith('http')) {
                          return CachedNetworkImage(
                            imageUrl: artUri,
                            width: 260,
                            height: 260,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Image.asset(
                              RadioConfig.logoAssetPath,
                              width: 260,
                              height: 260,
                            ),
                            errorWidget: (_, __, ___) => Image.asset(
                              RadioConfig.logoAssetPath,
                              width: 260,
                              height: 260,
                            ),
                          );
                        }
                        return Image.asset(artUri, width: 260, height: 260);
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  StreamBuilder<MediaItem?>(
                    stream: audioHandler.mediaItem,
                    builder: (context, snapshot) {
                      final item = snapshot.data;
                      return Column(
                        children: [
                          Text(
                            item?.title ?? RadioConfig.stationName,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item?.artist ?? '',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70, fontSize: 16),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 32),
                  StreamBuilder<PlaybackState>(
                    stream: audioHandler.playbackState,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      return IconButton(
                        iconSize: 72,
                        color: Colors.white,
                        icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
                        onPressed: () => playing ? audioHandler.pause() : audioHandler.play(),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
