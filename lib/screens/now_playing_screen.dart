import 'dart:io' show Platform;
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../radio_config.dart';
import '../services/diag_log.dart';
import '../widgets/cast_airplay_button.dart';
import '../widgets/vinyl_player.dart';
import 'playlist_screen.dart';
import 'request_song_screen.dart';
import 'timer_sveglia_dialog.dart';

class NowPlayingScreen extends StatelessWidget {
  final AudioHandler audioHandler;

  const NowPlayingScreen({super.key, required this.audioHandler});

  void _showInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Informazioni sviluppatore'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CachedNetworkImage(
              imageUrl: RadioConfig.infoLogoUrl,
              height: 60,
              errorWidget: (_, __, ___) => const SizedBox(height: 60),
            ),
            const SizedBox(height: 16),
            Text(RadioConfig.infoText, textAlign: TextAlign.center),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _condividiLogDiagnostico(context),
            child: const Text('Condividi log diagnostico'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Chiudi'),
          ),
        ],
      ),
    );
  }

  void _condividiLogDiagnostico(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? (box.localToGlobal(Offset.zero) & box.size) : null;
    SharePlus.instance.share(
      ShareParams(
        text: DiagLog.dump(),
        subject: 'Saurosoft Radio - log diagnostico',
        sharePositionOrigin: origin,
      ),
    );
  }

  void _showTimerSvegliaDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => TimerSvegliaDialog(audioHandler: audioHandler),
    );
  }

  void _openPlaylist(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlaylistScreen()),
    );
  }

  void _openRequestSong(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RequestSongScreen()),
    );
  }

  void _condividi(BuildContext context, MediaItem? item) {
    final title = item?.title ?? RadioConfig.stationName;
    final artist = item?.artist ?? '';
    final brano = (title.isNotEmpty && title != RadioConfig.stationName)
        ? '"$title"${artist.isNotEmpty ? ' di $artist' : ''}'
        : null;
    final testo = brano != null
        ? 'Sto ascoltando $brano su ${RadioConfig.stationName}!\n${RadioConfig.website}'
        : 'Sto ascoltando ${RadioConfig.stationName}!\n${RadioConfig.website}';

    // Su iOS (dalla versione 26) il foglio di condivisione richiede sempre
    // un punto di ancoraggio (sharePositionOrigin), anche su iPhone.
    // Senza questo parametro il pulsante non apre nulla.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? (box.localToGlobal(Offset.zero) & box.size) : null;

    SharePlus.instance.share(
      ShareParams(text: testo, sharePositionOrigin: origin),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Sfondo stagionale: immagine remota, stessa logica di
          // RadioConfig.sfondoStagionale() nell'app Android.
          CachedNetworkImage(
            imageUrl: RadioConfig.sfondoStagionale(),
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(color: const Color(0xFF12151C)),
          ),
          // Overlay scuro semi-trasparente, stesso valore di MainActivity.kt (0x99121212)
          Container(color: const Color(0x99121212)),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.queue_music, color: Colors.white, size: 32),
                            tooltip: 'Playlist',
                            onPressed: () => _openPlaylist(context),
                          ),
                          IconButton(
                            icon: const Icon(Icons.playlist_add, color: Colors.white, size: 32),
                            tooltip: 'Richiedi una canzone',
                            onPressed: () => _openRequestSong(context),
                          ),
                          IconButton(
                            icon: const Icon(Icons.access_alarm, color: Colors.white, size: 30),
                            tooltip: 'Timer e sveglia',
                            onPressed: () => _showTimerSvegliaDialog(context),
                          ),
                          const CastAirplayButton(),
                        ],
                      ),
                      Row(
                        children: [
                          StreamBuilder<MediaItem?>(
                            stream: audioHandler.mediaItem,
                            builder: (context, snapshot) {
                              return IconButton(
                                icon: const Icon(Icons.share, color: Colors.white, size: 28),
                                tooltip: 'Condividi',
                                onPressed: () => _condividi(context, snapshot.data),
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.info_outline, color: Color(0xFF4FC3F7), size: 32),
                            tooltip: 'Informazioni sviluppatore',
                            onPressed: () => _showInfoDialog(context),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_useVinyl)
                          _VinylArea(audioHandler: audioHandler)
                        else
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: StreamBuilder<MediaItem?>(
                            stream: audioHandler.mediaItem,
                            builder: (context, snapshot) {
                              // Su iOS artUri puo' essere il disco per CarPlay (file
                              // locale): il telefono usa la copertina originale.
                              final item = snapshot.data;
                              final artUri = (item?.extras?['cover'] as String?) ??
                                  item?.artUri?.toString() ??
                                  RadioConfig.fallbackLogoUrl;
                              return CachedNetworkImage(
                                imageUrl: artUri,
                                width: 260,
                                height: 260,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => Container(
                                  width: 260,
                                  height: 260,
                                  color: Colors.white24,
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 28),
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
                                  item?.artist ?? RadioConfig.tagline,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 36),
                        StreamBuilder<PlaybackState>(
                          stream: audioHandler.playbackState,
                          builder: (context, snapshot) {
                            final playing = snapshot.data?.playing ?? false;
                            return Column(
                              children: [
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                  child: IconButton(
                                    iconSize: 36,
                                    color: const Color(0xFF12151C),
                                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                                    onPressed: () => playing ? audioHandler.pause() : audioHandler.play(),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                SizedBox(
                                  height: 18,
                                  child: playing ? _BufferBars(audioHandler: audioHandler) : null,
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Disco in vinile solo su iPhone (l'app Android e' seguita a parte): per
// abilitarlo anche li basta mettere `true`.
final bool _useVinyl = Platform.isIOS;

/// Copertina rotante in un disco con braccio e puntina, piu' l'equalizzatore
/// simulato. Usa la copertina originale (extras['cover']), non il disco
/// composto per CarPlay.
class _VinylArea extends StatelessWidget {
  final AudioHandler audioHandler;

  const _VinylArea({required this.audioHandler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, itemSnapshot) {
        final item = itemSnapshot.data;
        final cover = (item?.extras?['cover'] as String?) ??
            item?.artUri?.toString() ??
            RadioConfig.fallbackLogoUrl;
        return StreamBuilder<PlaybackState>(
          stream: audioHandler.playbackState,
          builder: (context, stateSnapshot) {
            final playing = stateSnapshot.data?.playing ?? false;
            return FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VinylPlayer(coverUrl: cover, playing: playing),
                  const SizedBox(height: 10),
                  SimulatedEqualizer(playing: playing),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Indicatore discreto del buffer (5 tacche): secondi di audio gia' scaricato
/// ma non ancora suonato. Riceve il valore dal RadioAudioHandler (customEvent).
class _BufferBars extends StatelessWidget {
  final AudioHandler audioHandler;

  const _BufferBars({required this.audioHandler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<dynamic>(
      stream: audioHandler.customEvent,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final ahead =
            (data is Map && data['bufferAhead'] is num) ? (data['bufferAhead'] as num).toDouble() : 0.0;
        final bars = ahead <= 0.5 ? 0 : (ahead / 3).ceil().clamp(1, 5).toInt();
        return Tooltip(
          message: 'Buffer: ${ahead.toStringAsFixed(0)} s',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 1; i <= 5; i++)
                Container(
                  width: 4,
                  height: 6.0 + i * 2,
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  decoration: BoxDecoration(
                    color: i <= bars ? Colors.white70 : Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
