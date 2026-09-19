import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../radio_config.dart';
import 'metadata_service.dart';

/// Cuore dell'app: un solo AudioHandler che alimenta contemporaneamente
/// lock screen (iOS/Android), notifica di riproduzione, Android Auto e
/// CarPlay. Equivalente cross-platform di PlaybackService.kt.
///
/// Stessa logica "live only" della versione Android (LiveOnlyPlayer):
/// pause() ferma davvero lo stream (non tiene il buffer), play() riapre
/// una connessione fresca - cosi' non si sente mai audio "vecchio" dopo
/// una pausa lunga.
///
/// Nota CarPlay: l'entitlement "com.apple.developer.carplay-audio" va
/// richiesto separatamente ad Apple (vedi SETUP_MAC.md).
class RadioAudioHandler extends BaseAudioHandler with SeekHandler {
  // Tiene sempre ~15s di audio gia' scaricato ma non ancora suonato
  // (il server Icecast manda gia' un burst iniziale di ~15s per
  // riempirlo subito). Cosi' un buco di rete breve (es. galleria in
  // auto) viene assorbito dal buffer e non si sente affatto, invece di
  // aspettare che l'audio si interrompa per poi riconnettersi.
  static const _forwardBuffer = Duration(seconds: 15);

  final AudioPlayer _player = AudioPlayer(
    audioLoadConfiguration: AudioLoadConfiguration(
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false,
        preferredForwardBufferDuration: _forwardBuffer,
      ),
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: _forwardBuffer,
        maxBufferDuration: const Duration(seconds: 30),
        bufferForPlaybackDuration: _forwardBuffer,
        bufferForPlaybackAfterRebufferDuration: _forwardBuffer,
      ),
    ),
  );
  final MetadataService _metadataService = MetadataService();

  Timer? _pollTimer;
  Timer? _sleepTimer;
  Timer? _bufferingWatchdog;
  StreamSubscription<ProcessingState>? _processingStateSub;
  bool _wasPlayingBeforeError = false;
  String _lastArtist = '';
  String _lastTitle = '';

  /// Nomi delle custom action esposte a lock screen/UI, stessa idea dei
  /// SessionCommand custom di PlaybackService.kt.
  static const String actionSetSleepTimer = 'setSleepTimer';
  static const String actionCancelSleepTimer = 'cancelSleepTimer';

  RadioAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    _player.playbackEventStream.listen(
      (event) {
        playbackState.add(playbackState.value.copyWith(
          controls: [
            if (_player.playing) MediaControl.pause else MediaControl.play,
            MediaControl.stop,
          ],
          systemActions: const {MediaAction.play, MediaAction.pause},
          androidCompactActionIndices: const [0],
          processingState: _mapProcessingState(_player.processingState),
          playing: _player.playing,
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          speed: _player.speed,
        ));
      },
      onError: (Object e, StackTrace st) => _handleStreamError(),
    );

    // Il buffer di ~15s (vedi _forwardBuffer) assorbe da solo i buchi di
    // rete brevi: se il player entra comunque in "buffering" vuol dire
    // che quel margine e' gia' stato consumato del tutto (interruzione
    // piu' lunga del previsto), e su iOS AVPlayer spesso NON emette mai
    // un errore esplicito in quel caso - resta bloccato in attesa senza
    // che playbackEventStream.onError scatti mai. Questo watchdog copre
    // quel caso: se restiamo in buffering troppo a lungo mentre dovremmo
    // star suonando, trattiamo la cosa come un errore e ricarichiamo lo
    // stream.
    _processingStateSub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.buffering && _wasPlayingBeforeError) {
        _bufferingWatchdog ??= Timer(const Duration(seconds: 5), () {
          _bufferingWatchdog = null;
          _handleStreamError();
        });
      } else {
        _bufferingWatchdog?.cancel();
        _bufferingWatchdog = null;
      }
    });

    mediaItem.add(MediaItem(
      id: RadioConfig.streamUrl,
      title: RadioConfig.stationName,
      artist: RadioConfig.tagline,
      artUri: Uri.parse(RadioConfig.fallbackLogoUrl),
    ));

    await _loadStream();
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

  Future<void> _loadStream() async {
    try {
      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(RadioConfig.streamUrl),
          headers: const {'User-Agent': 'SaurosoftRadioApp/1.0'},
        ),
      );
    } catch (_) {
      _handleStreamError();
    }
  }

  /// Se lo streaming si interrompe per un errore di rete, riproviamo da
  /// soli dopo 3 secondi - stesso comportamento di PlaybackService.kt.
  void _handleStreamError() {
    Future.delayed(const Duration(seconds: 3), () async {
      await _loadStream();
      if (_wasPlayingBeforeError) {
        await _player.play();
      }
    });
  }

  void _startMetadataPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      Duration(seconds: RadioConfig.metadataPollIntervalSeconds),
      (_) => _refreshMetadata(),
    );
    _refreshMetadata();
  }

  Future<void> _refreshMetadata() async {
    final nowPlaying = await _metadataService.fetchNowPlaying();
    if (nowPlaying.artist == _lastArtist && nowPlaying.title == _lastTitle) {
      return;
    }
    _lastArtist = nowPlaying.artist;
    _lastTitle = nowPlaying.title;

    mediaItem.add(MediaItem(
      id: RadioConfig.streamUrl,
      title: nowPlaying.title,
      artist: nowPlaying.subtitle(),
      artUri: Uri.parse(nowPlaying.cover),
    ));
  }

  @override
  Future<void> play() async {
    _wasPlayingBeforeError = true;
    // Stesso comportamento di LiveOnlyPlayer.play(): se il player e' in
    // stato idle (dopo un pause "vero" o un errore), ricarica lo stream
    // da zero invece di riprendere un buffer vecchio.
    if (_player.processingState == ProcessingState.idle ||
        _player.processingState == ProcessingState.completed) {
      await _loadStream();
    }
    await _player.play();
  }

  @override
  Future<void> pause() async {
    _wasPlayingBeforeError = false;
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;
    // Stesso comportamento di LiveOnlyPlayer.pause(): stop vero, non una
    // pausa che tiene il buffer, cosi' alla ripresa si riparte dal vivo.
    await _player.stop();
  }

  @override
  Future<void> stop() async {
    _wasPlayingBeforeError = false;
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;
    await _player.stop();
    _pollTimer?.cancel();
    return super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    // Streaming live: il seek non ha senso, viene ignorato.
  }

  /// Sleep timer e sveglia passano da qui, stesso schema dei SessionCommand
  /// custom gestiti da LibrarySessionCallback in PlaybackService.kt.
  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case actionSetSleepTimer:
        final minuti = (extras?['minutes'] as num?)?.toInt() ?? 0;
        if (minuti > 0) _setSleepTimer(minuti);
        break;
      case actionCancelSleepTimer:
        _cancelSleepTimer();
        break;
    }
    return null;
  }

  void _setSleepTimer(int minuti) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(Duration(minutes: minuti), () => pause());
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  void dispose() {
    _pollTimer?.cancel();
    _sleepTimer?.cancel();
    _bufferingWatchdog?.cancel();
    _processingStateSub?.cancel();
    _player.dispose();
  }
}
