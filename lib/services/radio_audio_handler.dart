import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../radio_config.dart';
import 'metadata_service.dart';
import 'cover_art_service.dart';

/// Cuore dell'app: un solo AudioHandler che alimenta contemporaneamente
/// lock screen (iOS/Android), notifica di riproduzione, Android Auto e
/// CarPlay. E' l'equivalente cross-platform di PlaybackService.kt.
///
/// Nota CarPlay: l'entitlement "com.apple.developer.carplay-audio" va
/// richiesto separatamente ad Apple (approvazione manuale, vedi SETUP_MAC.md).
class RadioAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final MetadataService _metadataService = MetadataService();
  final CoverArtService _coverArtService = CoverArtService();

  Timer? _pollTimer;
  String _lastArtist = '';
  String _lastTitle = '';

  RadioAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    // Propaga lo stato del player (playing/paused/buffering) verso il sistema
    _player.playbackEventStream.listen((event) {
      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.rewind,
          if (_player.playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.play,
          MediaAction.pause,
        },
        androidCompactActionIndices: const [0, 1],
        processingState: _mapProcessingState(_player.processingState),
        playing: _player.playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
      ));
    });

    mediaItem.add(MediaItem(
      id: RadioConfig.streamUrl,
      title: RadioConfig.stationName,
      artist: 'In attesa dei dati...',
      artUri: Uri.parse(RadioConfig.logoAssetPath),
    ));

    await _player.setUrl(RadioConfig.streamUrl);
    _startMetadataPolling();
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  void _startMetadataPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      Duration(seconds: RadioConfig.metadataPollIntervalSeconds),
      (_) => _refreshMetadata(),
    );
    _refreshMetadata(); // prima chiamata subito, senza aspettare il primo tick
  }

  Future<void> _refreshMetadata() async {
    final nowPlaying = await _metadataService.fetchNowPlaying();
    if (nowPlaying.artist == _lastArtist && nowPlaying.title == _lastTitle) {
      return; // nessun cambiamento, evita di ridisegnare la UI inutilmente
    }
    _lastArtist = nowPlaying.artist;
    _lastTitle = nowPlaying.title;

    final coverUrl = nowPlaying.coverArtUrl ??
        await _coverArtService.findCoverArt(
          artist: nowPlaying.artist,
          title: nowPlaying.title,
        );

    mediaItem.add(MediaItem(
      id: RadioConfig.streamUrl,
      title: nowPlaying.title.isEmpty ? RadioConfig.stationName : nowPlaying.title,
      artist: nowPlaying.artist.isEmpty ? RadioConfig.stationName : nowPlaying.artist,
      artUri: Uri.parse(coverUrl),
    ));
  }

  @override
  Future<void> play() async {
    // Ricarica sempre l'URL con un token dinamico prima di ripartire:
    // evita il problema di stream "bloccato" dopo l'intro gia' visto in Android
    // (probabile redirect non seguito correttamente dal player precedente).
    if (_player.processingState == ProcessingState.idle ||
        _player.processingState == ProcessingState.completed) {
      await _player.setUrl(
        '${RadioConfig.streamUrl}?_a=${DateTime.now().millisecondsSinceEpoch}',
      );
    }
    await _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    _pollTimer?.cancel();
    return super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  void dispose() {
    _pollTimer?.cancel();
    _player.dispose();
  }
}
