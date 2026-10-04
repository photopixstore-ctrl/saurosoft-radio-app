import 'dart:async';
import 'dart:io' show Platform;
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import '../radio_config.dart';
import 'diag_log.dart';
import 'disc_artwork.dart';
import 'metadata_service.dart';

/// Cuore dell'app: un solo AudioHandler che alimenta contemporaneamente
/// lock screen (iOS/Android), notifica di riproduzione, Android Auto e
/// CarPlay. Equivalente cross-platform di PlaybackService.kt.
///
/// Stessa logica "live only" della versione Android (LiveOnlyPlayer):
/// pause() ferma davvero lo stream (non tiene il buffer) e ogni play()
/// riapre una connessione fresca - cosi' non si sente mai audio "vecchio"
/// ne' si riprende una connessione ormai morta.
///
/// Recupero errori: UN solo tentativo alla volta (generazione _loadGen) e
/// un controllo periodico (_livenessTick) che interviene su qualsiasi stato
/// "bloccato" (loading/buffering/idle/completed) mentre l'utente vuole
/// ascoltare. Tutto cio' che accade finisce in DiagLog.
class RadioAudioHandler extends BaseAudioHandler with SeekHandler {
  // Tiene sempre ~15s di audio gia' scaricato ma non ancora suonato
  // (il server Icecast manda gia' un burst iniziale di ~15s per
  // riempirlo subito). Cosi' un buco di rete breve (es. galleria in
  // auto) viene assorbito dal buffer e non si sente affatto.
  //
  // automaticallyWaitsToMinimizeStalling resta TRUE (default Apple): con
  // false AVPlayer, dopo uno stallo, puo' restare fermo senza ripartire da
  // solo anche quando il buffer si riempie di nuovo (stato "play acceso
  // ma nessun audio").
  static const _forwardBuffer = Duration(seconds: 15);

  // useProxyForRequestHeaders: false e' FONDAMENTALE. Con gli header
  // personalizzati (User-Agent) just_audio, di default, fa passare l'audio da
  // un piccolo server HTTP locale (127.0.0.1) dentro l'app e AVPlayer si
  // collega a quello. iOS chiude quel server quando l'app viene sospesa, ma
  // just_audio lo considera ancora attivo: da quel momento OGNI caricamento
  // (live e backup) fallisce subito (~30 ms) con "-1004 Could not connect to
  // the server" (visto nel log reale del 3/10, e spiega "play acceso ma
  // nessun audio" dopo una pausa lunga o uno stacco). Con false gli header
  // vanno direttamente ad AVPlayer, senza proxy.
  final AudioPlayer _player = AudioPlayer(
    useProxyForRequestHeaders: false,
    audioLoadConfiguration: AudioLoadConfiguration(
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: true,
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
  Timer? _retryTimer;
  Timer? _livenessTimer;
  Timer? _backupRecoveryTimer;
  Timer? _carPlayWaitTimeout;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<void>? _becomingNoisySub;
  StreamSubscription<void>? _devicesChangedSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;

  // Intento dell'utente: true da play() fino a pause()/stop().
  bool _wasPlayingBeforeError = false;
  bool _usingBackup = false;
  bool _waitingForCarPlay = false;
  bool _interrupted = false;
  bool _loadInFlight = false;
  bool _sessionStarted = false;
  static final bool _isIos = Platform.isIOS;
  static const MethodChannel _carPlayChannel =
      MethodChannel('it.photopix.saurosoft/carplay');
  DateTime? _carPlayLostAt;
  int _loadGen = 0;
  int _consecutiveErrors = 0;
  int _tickCount = 0;
  DateTime _stateSince = DateTime.now();
  String _lastArtist = '';
  String _lastTitle = '';

  // Buffer = secondi di audio gia' scaricato ma non ancora suonato. Su iOS la
  // posizione di riproduzione di questo stream resta sempre 0, ma
  // bufferedPosition cresce in tempo reale (log reale del 3/10: +10s ogni
  // 10s, ~13s in piu' del tempo ascoltato). Il buffer si ricava quindi
  // sottraendo il tempo di ascolto effettivo (ready+playing) misurato qui.
  double _playedSeconds = 0;
  DateTime? _activeSince;
  int _bufferBars = -1;
  DateTime _lastBarsPush = DateTime.fromMillisecondsSinceEpoch(0);
  MediaItem _baseItem = MediaItem(
    id: RadioConfig.streamUrl,
    title: RadioConfig.stationName,
    artist: RadioConfig.tagline,
    artUri: Uri.parse(RadioConfig.fallbackLogoUrl),
  );

  /// Nomi delle custom action esposte a lock screen/UI, stessa idea dei
  /// SessionCommand custom di PlaybackService.kt.
  static const String actionSetSleepTimer = 'setSleepTimer';
  static const String actionCancelSleepTimer = 'cancelSleepTimer';

  RadioAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    DiagLog.log('--- avvio handler ---');

    _player.playbackEventStream.listen(
      (event) => _publishState(),
      onError: (Object e, StackTrace st) {
        DiagLog.log('playbackEvent error: ${e.runtimeType} $e');
        // Errori ("Connection aborted") emessi mentre un caricamento e' in
        // corso arrivano dai caricamenti precedenti sostituiti: non sono
        // problemi dello stream (log reale 3/10: facevano scattare il backup
        // senza motivo). L'esito del caricamento in corso lo gestisce
        // _loadAndPlay.
        if (_loadInFlight) return;
        _handleStreamError('playbackEvent error');
      },
    );

    _playerStateSub = _player.playerStateStream.listen((state) {
      final now = DateTime.now();
      _stateSince = now;
      final activeSince = _activeSince;
      if (activeSince != null) {
        _playedSeconds += now.difference(activeSince).inMilliseconds / 1000.0;
        _activeSince = null;
      }
      if (state.playing && state.processingState == ProcessingState.ready) {
        _activeSince = now;
      }
      _publishState();
      DiagLog.log(
        'state playing=${state.playing} proc=${state.processingState.name} '
        'pos=${_player.position.inSeconds}s backup=$_usingBackup',
      );
      // Il server puo' chiudere la connessione "pulito" (es. Icecast
      // fermato): il player lo legge come fine naturale ("completed"). Per
      // una radio live non esiste una fine naturale, quindi e' un'interruzione.
      if (state.processingState == ProcessingState.completed &&
          _wasPlayingBeforeError) {
        _handleStreamError('completed');
      }
    });

    await _watchAudioSession();

    // La scena CarPlay (nativa, ios/Runner/CarPlaySceneDelegate.swift) chiede
    // l'avvio dell'ascolto da qui: il motore Dart e' unico e condiviso con
    // la schermata del telefono.
    _carPlayChannel.setMethodCallHandler((call) async {
      DiagLog.log('carplay -> ${call.method}');
      switch (call.method) {
        case 'play':
          await play();
          break;
        case 'pause':
          await pause();
          break;
      }
      return null;
    });

    mediaItem.add(_baseItem);

    // Nessun precaricamento dello stream all'avvio: una connessione aperta
    // senza ascoltare resta ferma mesi... e al primo play si rischia di
    // riprendere una connessione ormai chiusa dal server. Ogni play() apre
    // una connessione nuova (e non conta come ascoltatore chi apre l'app).
    _startMetadataPolling();
  }

  /// Interruzioni audio e cambi di rotta (CarPlay/cuffie).
  ///
  /// Scollegare CarPlay (o le cuffie) e' un cambio di rotta audio, non un
  /// "errore": iOS mette in pausa da solo (comportamento standard Apple,
  /// per non far esplodere l'audio a sorpresa dallo speaker del telefono)
  /// e NON riparte da solo. Su richiesta esplicita, facciamo un'eccezione
  /// MIRATA a CarPlay: se si ricollega entro 2 minuti (es. un buco di
  /// Bluetooth/USB mentre si guida), riprendiamo da soli con una connessione
  /// fresca. Nel frattempo nessun recupero automatico deve partire (altrimenti
  /// l'audio uscirebbe dallo speaker del telefono). Le cuffie restano con il
  /// comportamento standard.
  Future<void> _watchAudioSession() async {
    final session = await AudioSession.instance;

    _interruptionSub = session.interruptionEventStream.listen((event) {
      DiagLog.log('interruption begin=${event.begin} type=${event.type.name}');
      // Il "duck" (es. voce del navigatore) abbassa solo il volume.
      if (event.type == AudioInterruptionType.duck) return;
      _interrupted = event.begin;
      _stateSince = DateTime.now();
    });

    _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
      DiagLog.log('becomingNoisy (rotta audio persa) wantPlaying=$_wasPlayingBeforeError');
      if (!_wasPlayingBeforeError) return;
      _waitingForCarPlay = true;
      _carPlayLostAt = DateTime.now();
      _loadGen++;
      _loadInFlight = false;
      _retryTimer?.cancel();
      _retryTimer = null;
      _carPlayWaitTimeout?.cancel();
      _carPlayWaitTimeout = Timer(const Duration(minutes: 2), () {
        DiagLog.log('CarPlay non tornato entro 2 minuti: resto in pausa');
        _waitingForCarPlay = false;
        _wasPlayingBeforeError = false;
        _stopLiveness();
      });
    });

    _devicesChangedSub = session.devicesChangedEventStream.listen((_) async {
      final devices = await session.getDevices();
      final summary = devices
          .map((d) => '${d.type.name}${d.isOutput ? "(out)" : ""}')
          .join(',');
      DiagLog.log('devicesChanged: $summary waitingCarPlay=$_waitingForCarPlay');
      if (!_waitingForCarPlay) return;
      final carPlayIsBack = devices.any(
        (d) => d.isOutput && d.type == AudioDeviceType.carAudio,
      );
      if (carPlayIsBack) {
        _waitingForCarPlay = false;
        _carPlayWaitTimeout?.cancel();
        _carPlayWaitTimeout = null;
        // Il timer dei 2 minuti non e' affidabile se l'app e' stata sospesa:
        // si confronta l'orario di perdita.
        final lostAt = _carPlayLostAt;
        final withinWindow = lostAt != null &&
            DateTime.now().difference(lostAt) <= const Duration(minutes: 2);
        if (!withinWindow) {
          DiagLog.log('CarPlay tornato dopo piu\' di 2 minuti: resto in pausa');
          _wasPlayingBeforeError = false;
          _stopLiveness();
          _publishState();
          return;
        }
        // L'interruzione "unknown" emessa da iOS alla perdita della rotta non
        // ha un evento di fine: va azzerata qui, altrimenti il controllo
        // periodico resterebbe disattivato.
        _interrupted = false;
        DiagLog.log('CarPlay tornato: riprendo con connessione fresca');
        _startLiveness();
        await _loadAndPlay(
          _usingBackup ? RadioConfig.backupStreamUrl : RadioConfig.streamUrl,
        );
      }
    });
  }

  /// Stato mostrato a lock screen/UI/CarPlay, calcolato dall'INTENTO
  /// dell'utente e dallo stato reale del player. Va richiamato a ogni
  /// cambiamento, anche quando il player non emette eventi (es. stop() su
  /// un player gia' fermo dopo un errore): senza, il pulsante restava su
  /// "pausa" con nessun audio.
  void _publishState() {
    final wantsPlay = _wasPlayingBeforeError && !_waitingForCarPlay;
    final showPlaying = _player.playing || wantsPlay;
    final AudioProcessingState processing;
    if (!wantsPlay) {
      // Su iOS audio_service, appena lo stato pubblicato diventa "idle",
      // chiama stopService: toglie il comando Play dal centro comandi e
      // cancella il Now Playing. Dopo uno stop dall'auto/lock screen il tasto
      // Play non aveva piu' nessun destinatario e non faceva nulla. Dopo il
      // primo avvio quindi si resta su "ready" (in pausa, comandi attivi).
      final mapped = _mapProcessingState(_player.processingState);
      processing = (_isIos && _sessionStarted && mapped == AudioProcessingState.idle)
          ? AudioProcessingState.ready
          : mapped;
    } else if (_player.playing && _player.processingState == ProcessingState.ready) {
      processing = AudioProcessingState.ready;
    } else if (_player.processingState == ProcessingState.buffering) {
      processing = AudioProcessingState.buffering;
    } else {
      processing = AudioProcessingState.loading;
    }
    playbackState.add(playbackState.value.copyWith(
      controls: [
        if (showPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.play, MediaAction.pause},
      androidCompactActionIndices: const [0],
      processingState: processing,
      playing: showPlaying,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    ));
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

  Future<void> _setSource(String url) {
    return _player.setAudioSource(
      AudioSource.uri(
        Uri.parse(url),
        headers: const {'User-Agent': 'SaurosoftRadioApp/1.0'},
      ),
    );
  }

  /// Carica `url` da zero e, se l'utente vuole ascoltare, avvia la
  /// riproduzione. E' l'UNICO punto che carica sorgenti per il recupero:
  /// ogni chiamata invalida le precedenti (_loadGen), cosi' non possono mai
  /// sovrapporsi due caricamenti che si cancellano a vicenda.
  Future<void> _loadAndPlay(String url) async {
    final gen = ++_loadGen;
    _loadInFlight = true;
    _playedSeconds = 0;
    _activeSince = null;
    _publishState();
    DiagLog.log('load start -> $url');
    try {
      await _setSource(url).timeout(const Duration(seconds: 15));
      if (gen != _loadGen) return;
      DiagLog.log('load ok');
      _loadInFlight = false;
      if (_wasPlayingBeforeError && !_waitingForCarPlay) _startPlayer();
    } on PlayerInterruptedException {
      DiagLog.log('load interrotto (sostituito da uno piu\' recente)');
    } catch (e) {
      DiagLog.log('load fallito: ${e.runtimeType} $e');
      if (gen == _loadGen) {
        _loadInFlight = false;
        _handleStreamError('load fallito');
      }
    } finally {
      if (gen == _loadGen) _loadInFlight = false;
      _publishState();
    }
  }

  /// play() del player senza attenderlo (il suo Future termina solo quando
  /// la riproduzione si ferma) ma senza lasciare errori non gestiti.
  void _startPlayer() {
    unawaited(_player.play().catchError((Object e) {
      DiagLog.log('player.play() errore: ${e.runtimeType} $e');
    }));
  }

  /// Qualsiasi segnale di stream interrotto passa da qui. Piu' segnali
  /// ravvicinati si fondono in un solo tentativo dopo 3 secondi.
  void _handleStreamError(String why, {Duration delay = const Duration(seconds: 3)}) {
    DiagLog.log('problema stream: $why');
    if (!_wasPlayingBeforeError || _waitingForCarPlay) return;
    if (_retryTimer?.isActive ?? false) return;
    _retryTimer = Timer(delay, _recover);
  }

  /// Se il LIVE continua a fallire (errori ripetuti, non un singolo blip),
  /// passiamo esplicitamente al file mp3 di riserva (RadioConfig
  /// .backupStreamUrl, su Serverplan, indipendente dalla VPS del live).
  Future<void> _recover() async {
    _retryTimer = null;
    if (!_wasPlayingBeforeError || _waitingForCarPlay) return;
    _consecutiveErrors++;
    if (!_usingBackup && _consecutiveErrors >= 2) {
      _usingBackup = true;
      _startBackupRecoveryTimer();
    }
    DiagLog.log(
      'recupero #$_consecutiveErrors -> ${_usingBackup ? "BACKUP" : "live"}',
    );
    await _loadAndPlay(
      _usingBackup ? RadioConfig.backupStreamUrl : RadioConfig.streamUrl,
    );
  }

  /// Mentre siamo sul backup, controlliamo periodicamente (senza toccare
  /// la riproduzione in corso) se il live e' tornato; se si', ci si torna.
  void _startBackupRecoveryTimer() {
    _backupRecoveryTimer?.cancel();
    _backupRecoveryTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_usingBackup) {
        _backupRecoveryTimer?.cancel();
        _backupRecoveryTimer = null;
        return;
      }
      if (!_wasPlayingBeforeError || _waitingForCarPlay || _loadInFlight) return;
      final up = await _liveIsUp();
      DiagLog.log('backup: live disponibile? $up');
      if (!up || !_usingBackup || !_wasPlayingBeforeError) return;
      _usingBackup = false;
      _consecutiveErrors = 0;
      _backupRecoveryTimer?.cancel();
      _backupRecoveryTimer = null;
      await _loadAndPlay(RadioConfig.streamUrl);
    });
  }

  Future<bool> _liveIsUp() async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(RadioConfig.streamUrl))
        ..headers['User-Agent'] = 'SaurosoftRadioApp/1.0';
      final response = await client.send(request).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return false;
      final first = await response.stream.first.timeout(const Duration(seconds: 5));
      return first.isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  void _startLiveness() {
    _livenessTimer ??=
        Timer.periodic(const Duration(seconds: 2), (_) => _livenessTick());
  }

  void _stopLiveness() {
    _livenessTimer?.cancel();
    _livenessTimer = null;
  }

  /// Controllo periodico: se l'utente vuole ascoltare ma il player resta
  /// troppo a lungo in uno stato che non produce audio, e' un problema
  /// anche se nessun errore esplicito e' mai stato emesso (su iOS
  /// AVPlayer spesso non lo emette).
  void _livenessTick() {
    if (!_wasPlayingBeforeError) return;
    _tickCount++;
    _publishBuffer();
    if (_tickCount % 5 == 0) {
      DiagLog.log(
        'health playing=${_player.playing} proc=${_player.processingState.name} '
        'ahead=${_bufferAheadSeconds().toStringAsFixed(1)}s buf=${_player.bufferedPosition.inSeconds}s '
        'backup=$_usingBackup inflight=$_loadInFlight carplay=$_waitingForCarPlay '
        'interrotto=$_interrupted',
      );
    }
    if (_waitingForCarPlay || _interrupted || _loadInFlight) return;
    if (_retryTimer?.isActive ?? false) return;

    final state = _player.processingState;
    final stuck = DateTime.now().difference(_stateSince);

    if (_player.playing && state == ProcessingState.ready) {
      if (stuck > const Duration(seconds: 10)) _consecutiveErrors = 0;
      return;
    }

    if (state == ProcessingState.ready) {
      // Pronto ma non in riproduzione mentre l'utente vuole ascoltare
      // (es. attivazione della sessione audio rifiutata): richiede il play.
      if (stuck > const Duration(seconds: 6)) {
        _stateSince = DateTime.now();
        DiagLog.log('pronto ma non in play: rilancio play()');
        _startPlayer();
      }
      return;
    }

    Duration limit;
    if (state == ProcessingState.buffering) {
      // Il backup e' un file finito: un rallentamento e' un normale buffering.
      // Live: dopo uno stallo la riconnessione e' sempre migliore di
      // aspettare (log reale 4/10: connessione ferma ~25 s, 17 s di silenzio
      // con il vecchio limite di 10 s + 3 s di attesa).
      limit = _usingBackup ? const Duration(seconds: 25) : const Duration(seconds: 5);
    } else if (state == ProcessingState.loading) {
      limit = const Duration(seconds: 12);
    } else {
      limit = const Duration(seconds: 4);
    }
    if (stuck > limit) {
      _stateSince = DateTime.now();
      _handleStreamError(
        'bloccato in ${state.name} da ${stuck.inSeconds}s',
        delay: const Duration(seconds: 1),
      );
    }
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

    _baseItem = MediaItem(
      id: RadioConfig.streamUrl,
      title: nowPlaying.title,
      artist: nowPlaying.subtitle(),
      artUri: Uri.parse(nowPlaying.cover),
      // La schermata del telefono mostra sempre la copertina originale,
      // anche quando artUri diventa il disco per CarPlay/lock screen.
      extras: {
        'cover': nowPlaying.cover,
        if (nowPlaying.songStartMs != null) 'songStartMs': nowPlaying.songStartMs,
        if (nowPlaying.durationSec != null) 'songDurationSec': nowPlaying.durationSec,
      },
    );
    _pushMediaItem();
    if (_isIos && nowPlaying.cover != RadioConfig.fallbackLogoUrl) {
      unawaited(_applyDiscArtwork(nowPlaying.cover));
    }
  }

  /// Sostituisce la copertina di CarPlay/lock screen con quella a forma di
  /// disco in vinile, se riesce a comporla e il brano e' ancora lo stesso.
  Future<void> _applyDiscArtwork(String cover) async {
    final disc = await DiscArtwork.compose(cover);
    if (disc == null || _baseItem.extras?['cover'] != cover) return;
    _baseItem = _baseItem.copyWith(artUri: disc);
    _pushMediaItem();
  }

  /// Pubblica il brano corrente. Il buffer NON e' piu' scritto nella riga
  /// "album" (Domenico l'ha voluto togliere da sotto l'artista): in auto resta
  /// solo il tasto con le tacche, sul telefono la barra sotto il tasto play.
  void _pushMediaItem() {
    mediaItem.add(_baseItem);
  }

  /// Tacche del buffer per il tasto della schermata "In riproduzione" di
  /// CarPlay (nativo): -1 quando non si sta ascoltando.
  void _sendBarsToCarPlay(int bars) {
    if (!_isIos) return;
    unawaited(_carPlayChannel
        .invokeMethod<void>('buffer', bars)
        .catchError((Object _) {}));
  }

  double _bufferAheadSeconds() {
    var played = _playedSeconds;
    final since = _activeSince;
    if (since != null) {
      played += DateTime.now().difference(since).inMilliseconds / 1000.0;
    }
    final ahead = _player.bufferedPosition.inMilliseconds / 1000.0 - played;
    if (ahead < 0) return 0;
    return ahead > 60 ? 60 : ahead;
  }

  /// Invia il livello di buffer alla schermata (customEvent) e, quando cambia
  /// il numero di tacche (max ogni 6 s), anche a CarPlay/lock screen.
  void _publishBuffer() {
    final active = _player.playing &&
        (_player.processingState == ProcessingState.ready ||
            _player.processingState == ProcessingState.buffering);
    final ahead = active ? _bufferAheadSeconds() : 0.0;
    customEvent.add({'bufferAhead': ahead});
    var bars = -1;
    if (active) {
      bars = ahead <= 0.5 ? 0 : (ahead / 3).ceil().clamp(1, 5).toInt();
    }
    final now = DateTime.now();
    if (bars != _bufferBars &&
        (bars == -1 || now.difference(_lastBarsPush) > const Duration(seconds: 6))) {
      _bufferBars = bars;
      _lastBarsPush = now;
      _sendBarsToCarPlay(bars);
    }
  }

  void _clearBuffer() {
    customEvent.add({'bufferAhead': 0.0});
    if (_bufferBars != -1) {
      _bufferBars = -1;
      _sendBarsToCarPlay(-1);
    }
  }

  void _cancelRecoveryState() {
    _loadGen++;
    _loadInFlight = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _backupRecoveryTimer?.cancel();
    _backupRecoveryTimer = null;
    _waitingForCarPlay = false;
    _carPlayWaitTimeout?.cancel();
    _carPlayWaitTimeout = null;
  }

  @override
  Future<void> play() async {
    DiagLog.log(
      'play() richiesto (playing=${_player.playing}, proc=${_player.processingState.name})',
    );
    _wasPlayingBeforeError = true;
    _sessionStarted = true;
    _startLiveness();
    _publishState();
    if (_player.playing && _player.processingState == ProcessingState.ready) {
      return;
    }
    // CarPlay e lock screen mandano piu' comandi play quasi insieme (visti 5
    // in 17 ms nel log reale del 3/10): se un caricamento e' gia' in corso
    // non se ne avvia un altro, altrimenti si sovrappongono, si abortiscono a
    // vicenda e fanno scattare il backup.
    if (_loadInFlight) {
      DiagLog.log('play() ignorato: caricamento gia\' in corso');
      return;
    }
    // Un play manuale riparte sempre dal LIVE con una connessione fresca,
    // anche se l'ultima sessione era finita sul backup.
    _cancelRecoveryState();
    _usingBackup = false;
    _consecutiveErrors = 0;
    _interrupted = false;
    _startLiveness();
    await _loadAndPlay(RadioConfig.streamUrl);
  }

  @override
  Future<void> pause() async {
    DiagLog.log('pause() richiesto');
    _wasPlayingBeforeError = false;
    _cancelRecoveryState();
    _stopLiveness();
    // Stesso comportamento di LiveOnlyPlayer.pause(): stop vero, non una
    // pausa che tiene il buffer, cosi' alla ripresa si riparte dal vivo.
    await _player.stop();
    _publishState();
    _clearBuffer();
  }

  @override
  Future<void> stop() async {
    DiagLog.log('stop() richiesto');
    _wasPlayingBeforeError = false;
    _cancelRecoveryState();
    _stopLiveness();
    await _player.stop();
    _publishState();
    _clearBuffer();
    // Su iOS niente super.stop(): porterebbe lo stato a idle e audio_service
    // smonterebbe i comandi, rendendo inutile il Play successivo (vedi
    // _publishState). Il polling dei metadati resta attivo.
    if (_isIos) return;
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
    _retryTimer?.cancel();
    _livenessTimer?.cancel();
    _backupRecoveryTimer?.cancel();
    _carPlayWaitTimeout?.cancel();
    _playerStateSub?.cancel();
    _becomingNoisySub?.cancel();
    _devicesChangedSub?.cancel();
    _interruptionSub?.cancel();
    _player.dispose();
  }
}
