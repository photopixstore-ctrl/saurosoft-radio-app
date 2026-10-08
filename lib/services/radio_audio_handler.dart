import 'dart:async';
import 'dart:io' show Platform;
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import '../radio_config.dart';
import 'diag_log.dart';
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
  // Tiene fino a 30 s di audio gia' scaricato ma non ancora suonato: ~15 s
  // arrivano subito (burst del server Icecast), il resto si guadagna con la
  // pausa di 3 s all'avvio, con le pause di sistema (chiamate) e con un lieve
  // rallentamento lato app (_updateSlowdown). Cosi' un buco di rete breve (es. galleria in
  // auto) viene assorbito dal buffer e non si sente affatto.
  //
  // automaticallyWaitsToMinimizeStalling resta TRUE (default Apple): con
  // false AVPlayer, dopo uno stallo, puo' restare fermo senza ripartire da
  // solo anche quando il buffer si riempie di nuovo (stato "play acceso
  // ma nessun audio").
  static const _forwardBuffer = Duration(seconds: 30);
  static const _startBuffer = Duration(seconds: 15);

  // useProxyForRequestHeaders: false e' FONDAMENTALE. Con gli header
  // personalizzati (User-Agent) just_audio, di default, fa passare l'audio da
  // un piccolo server HTTP locale (127.0.0.1) dentro l'app e AVPlayer si
  // collega a quello. iOS chiude quel server quando l'app viene sospesa, ma
  // just_audio lo considera ancora attivo: da quel momento OGNI caricamento
  // (live e backup) fallisce subito (~30 ms) con "-1004 Could not connect to
  // the server" (visto nel log reale del 3/10, e spiega "play acceso ma
  // nessun audio" dopo una pausa lunga o uno stacco). Con false gli header
  // vanno direttamente ad AVPlayer, senza proxy.
  //
  // Non e' final: nel cambio senza stacco (_seamlessReload) il player attivo
  // viene sostituito da uno nuovo gia' pronto.
  late AudioPlayer _player = _createPlayer();

  AudioPlayer _createPlayer() => AudioPlayer(
        useProxyForRequestHeaders: false,
        audioLoadConfiguration: AudioLoadConfiguration(
          darwinLoadControl: DarwinLoadControl(
            automaticallyWaitsToMinimizeStalling: true,
            preferredForwardBufferDuration: _forwardBuffer,
          ),
          androidLoadControl: AndroidLoadControl(
            minBufferDuration: _forwardBuffer,
            maxBufferDuration: const Duration(seconds: 40),
            bufferForPlaybackDuration: _startBuffer,
            bufferForPlaybackAfterRebufferDuration: _startBuffer,
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
  StreamSubscription<PlaybackEvent>? _playbackEventSub;
  // True mentre un nuovo player si prepara in parallelo a quello che suona.
  bool _swapping = false;

  // Rallentamento lato app (v11): mai lato server.
  static const double _slowSpeed = 0.985;
  static const bool _slowdownEnabled = false;

  // Flusso dedicato alle app: se non risponde si ripiega su radio.mp3 per qualche minuto.
  DateTime? _appStreamBadUntil;
  Timer? _metaTimer;
  // Correzione fine del ritardo dei titoli (secondi, anche negativa): da tarare in prova.
  static const double _metadataOffsetSec = 0.0;

  String _liveUrl() {
    final bad = _appStreamBadUntil;
    if (bad != null && DateTime.now().isBefore(bad)) return RadioConfig.streamUrl;
    return RadioConfig.appStreamUrl;
  }

  // Volume: salita graduale all'avvio e discesa rapida in pausa (a volume alto
  // lo stacco spaventa chi preme play).
  static const Duration _fadeInManual = Duration(seconds: 2);
  static const Duration _fadeInRecovery = Duration(milliseconds: 800);
  static const Duration _fadeOutTime = Duration(milliseconds: 500);
  double _volume = 1.0;
  int _fadeGen = 0;
  static const Duration _startDelay = Duration(seconds: 3);
  double _speed = 1.0;
  DateTime _lastTrouble = DateTime.fromMillisecondsSinceEpoch(0);
  double _aheadAtInterruption = 0;
  final List<MapEntry<DateTime, Duration>> _growthLog = [];
  StreamSubscription<void>? _becomingNoisySub;
  StreamSubscription<void>? _devicesChangedSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;

  // Intento dell'utente: true da play() fino a pause()/stop().
  bool _wasPlayingBeforeError = false;
  bool _usingBackup = false;
  bool _waitingForCarPlay = false;
  bool _interrupted = false;
  DateTime? _interruptedAt;
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
  Duration _lastBufferedPos = Duration.zero;
  DateTime _bufferGrewAt = DateTime.now();
  DateTime _lastProbeAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _probing = false;
  bool _networkWasDown = false;
  // Ultimo errore di caricamento causato da rete assente (-1009).
  bool _lastLoadOffline = false;
  DateTime? _activeSince;
  int _bufferBars = -1;
  DateTime _lastBarsPush = DateTime.fromMillisecondsSinceEpoch(0);
  MediaItem _baseItem = MediaItem(
    id: RadioConfig.streamUrl,
    title: RadioConfig.stationName,
    artist: RadioConfig.tagline,
    artUri: Uri.parse(RadioConfig.fallbackLogoUrl),
    isLive: true,
  );

  /// Nomi delle custom action esposte a lock screen/UI, stessa idea dei
  /// SessionCommand custom di PlaybackService.kt.
  static const String actionSetSleepTimer = 'setSleepTimer';
  static const String actionCancelSleepTimer = 'cancelSleepTimer';

  RadioAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    DiagLog.log('--- avvio handler (build rete v13) ---');

    _attachPlayerListeners();

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

    _pushMediaItem();

    // Nessun precaricamento dello stream all'avvio: una connessione aperta
    // senza ascoltare resta ferma mesi... e al primo play si rischia di
    // riprendere una connessione ormai chiusa dal server. Ogni play() apre
    // una connessione nuova (e non conta come ascoltatore chi apre l'app).
    _startMetadataPolling();
  }

  /// Collega gli ascoltatori di stato/errori al player attivo (`_player`).
  /// Va richiamato dopo ogni sostituzione del player.
  void _attachPlayerListeners() {
    _playbackEventSub?.cancel();
    _playerStateSub?.cancel();

    _playbackEventSub = _player.playbackEventStream.listen(
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
        _playedSeconds += now.difference(activeSince).inMilliseconds / 1000.0 * _speed;
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
      if (event.begin) {
        _interruptedAt = DateTime.now();
        _aheadAtInterruption = _bufferAheadSeconds();
        if (_wasPlayingBeforeError) {
          // Alla ripresa il suono rientra piano.
          _fadeGen++;
          _volume = 0.0;
          unawaited(_player.setVolume(0.0).catchError((Object _) {}));
        }
      } else if (_wasPlayingBeforeError && !_waitingForCarPlay) {
        final at = _interruptedAt;
        _interruptedAt = null;
        // Dopo una pausa lunga (chiamata, WhatsApp) il player riprenderebbe
        // dal punto fermo, in ritardo sulla diretta: ci si riallinea al live
        // (e titoli/copertine tornano sincronizzati).
        // Si riparte dal buffer finche' il ritardo totale resta entro 30 s
        // (buffer a inizio pausa + durata della pausa); oltre, si riallinea.
        final limitSec = (30.0 - _aheadAtInterruption - 1.0).clamp(3.0, 30.0);
        if (at != null &&
            DateTime.now().difference(at).inMilliseconds / 1000.0 > limitSec) {
          DiagLog.log('interruzione lunga: riallineo al live');
          _cancelRecoveryState();
          _usingBackup = false;
          _consecutiveErrors = 0;
          unawaited(_loadAndPlay(_liveUrl()));
        } else {
          unawaited(_fadeTo(1.0, const Duration(seconds: 1)));
        }
      }
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
          _usingBackup ? RadioConfig.backupStreamUrl : _liveUrl(),
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
    _disableSkipCommands();
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
        headers: {'User-Agent': RadioConfig.userAgent},
      ),
    );
  }

  /// Carica la sorgente con tentativi ripetuti: dopo un taglio di rete i primi
  /// pacchetti si perdono e iOS ritenta con attese sempre piu' lunghe (3, 5, 11 s
  /// nei log reali dell'8/10). Un nuovo tentativo ogni pochi secondi aggancia la
  /// rete appena torna.
  Future<void> _setSourceRetrying(String url, int gen) async {
    const attempts = [
      Duration(milliseconds: 2500),
      Duration(milliseconds: 2500),
      Duration(seconds: 4),
      Duration(seconds: 6),
    ];
    for (var i = 0; i < attempts.length; i++) {
      try {
        await _setSource(url).timeout(attempts[i]);
        return;
      } on TimeoutException {
        if (gen != _loadGen) return;
        if (i == attempts.length - 1) rethrow;
        DiagLog.log('caricamento lento (tentativo ${i + 1}): riprovo');
      }
    }
  }

  /// Carica `url` da zero e, se l'utente vuole ascoltare, avvia la
  /// riproduzione. E' l'UNICO punto che carica sorgenti per il recupero:
  /// ogni chiamata invalida le precedenti (_loadGen), cosi' non possono mai
  /// sovrapporsi due caricamenti che si cancellano a vicenda.
  Future<void> _loadAndPlay(
    String url, {
    Duration startDelay = Duration.zero,
    bool manualStart = false,
  }) async {
    final gen = ++_loadGen;
    _loadInFlight = true;
    _resetSpeed();
    _playedSeconds = 0;
    _activeSince = null;
    _lastBufferedPos = Duration.zero;
    _bufferGrewAt = DateTime.now();
    _publishState();
    DiagLog.log('load start -> $url');
    try {
      await _setSourceRetrying(url, gen);
      if (gen != _loadGen) return;
      DiagLog.log('load ok');
      if (startDelay > Duration.zero) {
        // Attesa iniziale: il buffer sale di altri secondi prima di suonare.
        DiagLog.log('attesa iniziale di ${startDelay.inSeconds} s per il buffer');
        await Future<void>.delayed(startDelay);
        if (gen != _loadGen) return;
      }
      _loadInFlight = false;
      _lastLoadOffline = false;
      if (_wasPlayingBeforeError && !_waitingForCarPlay) {
        // Avvio con volume a zero e salita graduale.
        _fadeGen++;
        _volume = 0.0;
        try {
          await _player.setVolume(0.0);
        } catch (_) {}
        if (gen != _loadGen) return;
        _startPlayer();
        unawaited(_fadeTo(
          1.0,
          manualStart ? _fadeInManual : _fadeInRecovery,
        ));
      }
    } on PlayerInterruptedException {
      DiagLog.log('load interrotto (sostituito da uno piu\' recente)');
    } catch (e) {
      DiagLog.log('load fallito: ${e.runtimeType} $e');
      if (gen == _loadGen) {
        _loadInFlight = false;
        _lastLoadOffline = _isOfflineError(e);
        if (url == RadioConfig.appStreamUrl && !_lastLoadOffline) {
          _appStreamBadUntil = DateTime.now().add(const Duration(minutes: 3));
          _consecutiveErrors = 0;
          DiagLog.log('flusso app non risponde: ripiego su radio.mp3 per 3 minuti');
        }
        _handleStreamError(
          'load fallito',
          delay: Duration(seconds: _lastLoadOffline ? 2 : 3),
        );
      }
    } finally {
      if (gen == _loadGen) _loadInFlight = false;
      _publishState();
    }
  }

  /// Cambio senza stacco: il nuovo flusso live si carica su un SECONDO player
  /// mentre il primo continua a suonare l'audio che gli resta nel buffer; solo
  /// a nuovo flusso pronto si passa a quello nuovo. (Con setAudioSource sul
  /// player unico l'audio si fermava subito, anche con 6-9 s di buffer, e
  /// restava il vuoto del ricaricamento: log reale 4/10, identico per tagli
  /// da 5, 10 e 15 s.) Il nuovo flusso riparte circa 1-2 s prima del punto
  /// in cui era il vecchio (burst del server): puo' ripetersi una frazione di
  /// audio, ma niente silenzio. Se il caricamento fallisce si ricade sul
  /// ricaricamento classico.
  Future<void> _seamlessReload() async {
    final gen = ++_loadGen;
    _loadInFlight = true;
    _swapping = true;
    final startedAt = DateTime.now();
    DiagLog.log(
      'cambio senza stacco: preparo nuovo flusso (buffer residuo '
      '${_bufferAheadSeconds().toStringAsFixed(1)}s)',
    );
    _lastTrouble = DateTime.now();
    var fresh = _createPlayer();
    final bufferedAtStart = _player.bufferedPosition;
    var swapped = false;
    try {
      const swapAttempts = [
        Duration(milliseconds: 2500),
        Duration(milliseconds: 2500),
        Duration(seconds: 4),
      ];
      for (var i = 0; i < swapAttempts.length; i++) {
        try {
          await fresh
              .setAudioSource(
                AudioSource.uri(
                  Uri.parse(_liveUrl()),
                  headers: {'User-Agent': RadioConfig.userAgent},
                ),
              )
              .timeout(swapAttempts[i]);
          break;
        } on TimeoutException {
          if (i == swapAttempts.length - 1) rethrow;
          if (gen != _loadGen) break;
          DiagLog.log('cambio senza stacco: caricamento lento (tentativo ${i + 1}), riprovo');
          unawaited(fresh.dispose().catchError((Object _) {}));
          fresh = _createPlayer();
        }
      }
      if (gen != _loadGen || !_wasPlayingBeforeError || _waitingForCarPlay) {
        DiagLog.log('cambio senza stacco annullato');
        return;
      }
      // Se mentre il nuovo flusso si caricava il vecchio e' ripreso da solo
      // (buffer cresciuto), il cambio non serve: farlo ripeterebbe audio
      // (log reale 6/10: stallo di 9 s, vecchio flusso ripreso 1 s dopo, il
      // cambio ha ripetuto ~4 s).
      if (_player.bufferedPosition - bufferedAtStart >= const Duration(seconds: 3)) {
        DiagLog.log("cambio senza stacco annullato: il vecchio flusso e' ripreso da solo");
        return;
      }
      final old = _player;
      final aheadAtSwap = _bufferAheadSeconds();
      _player = fresh;
      swapped = true;
      _fadeGen++;
      _volume = 1.0;
      _speed = 1.0;
      _growthLog.clear();
      final now = DateTime.now();
      _playedSeconds = 0;
      _activeSince = null;
      _lastBufferedPos = Duration.zero;
      _bufferGrewAt = now;
      _networkWasDown = false;
      _stateSince = now;
      _attachPlayerListeners();
      _startPlayer();
      unawaited(() async {
        try {
          await old.setVolume(0);
          await old.stop();
        } catch (_) {}
        try {
          await old.dispose();
        } catch (_) {}
      }());
      _lastLoadOffline = false;
      DiagLog.log(
        'cambio senza stacco: fatto in '
        '${DateTime.now().difference(startedAt).inMilliseconds} ms '
        '(buffer vecchio residuo ${aheadAtSwap.toStringAsFixed(1)}s)',
      );
    } on PlayerInterruptedException {
      DiagLog.log('cambio senza stacco interrotto');
    } catch (e) {
      DiagLog.log('cambio senza stacco fallito: ${e.runtimeType} $e');
      if (gen == _loadGen) {
        _lastLoadOffline = _isOfflineError(e);
        _loadInFlight = false;
        _swapping = false;
        // Ricaricamento classico (il vecchio flusso e' comunque in stallo).
        unawaited(_loadAndPlay(RadioConfig.streamUrl));
      }
    } finally {
      if (!swapped) unawaited(fresh.dispose().catchError((Object _) {}));
      if (gen == _loadGen) _loadInFlight = false;
      _swapping = false;
      _publishState();
    }
  }

  bool _isOfflineError(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('-1009') || text.contains('appears to be offline');
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
    _lastTrouble = DateTime.now();
    if (!_wasPlayingBeforeError || _waitingForCarPlay) return;
    if (_retryTimer?.isActive ?? false) return;
    _retryTimer = Timer(delay, _recover);
  }

  /// Se il LIVE continua a fallire (errori ripetuti, non un singolo blip),
  /// passiamo esplicitamente al file mp3 di riserva (RadioConfig
  /// .backupStreamUrl, su Serverplan, indipendente dalla VPS del live).
  Future<void> _recover() async {
    _retryTimer = null;
    if (!_wasPlayingBeforeError || _waitingForCarPlay || _swapping) return;
    // Live ancora in riproduzione con audio nel buffer: nuovo flusso preparato
    // in parallelo, senza interrompere quello che sta suonando.
    if (!_usingBackup &&
        _player.playing &&
        _player.processingState == ProcessingState.ready &&
        _bufferAheadSeconds() >= 0.5) {
      await _seamlessReload();
      return;
    }
    // Senza rete anche il file di riserva e' irraggiungibile e, al ritorno
    // della rete, partirebbe da capo (stacco udibile): si insiste sul LIVE.
    if (!_lastLoadOffline) {
      _consecutiveErrors++;
      if (!_usingBackup && _consecutiveErrors >= 2) {
        _usingBackup = true;
        _startBackupRecoveryTimer();
      }
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
      await _loadAndPlay(_liveUrl());
    });
  }

  Future<bool> _liveIsUp({Duration timeout = const Duration(seconds: 5)}) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(RadioConfig.streamUrl))
        ..headers['User-Agent'] = '${RadioConfig.userAgent}-probe';
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode != 200) return false;
      final first = await response.stream.first.timeout(timeout);
      return first.isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  void _startLiveness() {
    _livenessTimer ??=
        Timer.periodic(const Duration(seconds: 1), (_) => _livenessTick());
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
    _updateSlowdown();
    if (_tickCount % 10 == 0) {
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

    // Connessione live ferma (log reale 4/10). Due casi distinti:
    // (a) la rete e' sparita e poi torna: appena un controllo leggero la
    //     ritrova si riconnette SUBITO, quando nel buffer c'e' ancora audio:
    //     il nuovo flusso parte circa dove sta suonando il vecchio (stacco
    //     minimo, niente file di riserva);
    // (b) la rete c'e' ma la connessione e' bloccata ("zombie"): si
    //     riconnette appena il buffer e' quasi vuoto e non cresce.
    if (_player.playing &&
        !_usingBackup &&
        (state == ProcessingState.ready || state == ProcessingState.buffering)) {
      final now = DateTime.now();
      final buffered = _player.bufferedPosition;
      if (buffered != _lastBufferedPos) {
        _lastBufferedPos = buffered;
        _bufferGrewAt = now;
        _networkWasDown = false;
      }
      final stagnant = now.difference(_bufferGrewAt);
      if (_playedNow() >= 8) {
        final ahead = _bufferAheadSeconds();
        // Il nuovo flusso parte circa dove sta suonando il vecchio (burst di
        // ~15 s = stesso ritardo dal live): riconnettersi PRIMA che il buffer
        // finisca, ma solo se la rete risponde (se e' giu', ricaricare
        // fermerebbe l'audio residuo senza ottenere niente).
        final nearEnd = ahead <= 3.5;
        if (stagnant > const Duration(seconds: 3) &&
            !_probing &&
            (_networkWasDown ||
                (nearEnd && now.difference(_lastProbeAt) > const Duration(seconds: 3)) ||
                // Buffer fermo da oltre 8 s: non e' un normale arrivo a blocchi (con 5 s
                // scattavano cambi inutili, log reale 4/10 ore 21:15)
                // (log reale 4/10: taglio da 5 s, rete tornata, flusso morto,
                // l'audio si fermava ~10 s dopo perche' si aspettava il buffer
                // quasi vuoto prima di riconnettersi).
                (stagnant > const Duration(seconds: 8) &&
                    now.difference(_lastProbeAt) > const Duration(seconds: 2)) ||
                now.difference(_lastProbeAt) > const Duration(seconds: 10))) {
          _probing = true;
          _lastProbeAt = now;
          unawaited(_liveIsUp(timeout: const Duration(seconds: 2)).then((up) {
            _probing = false;
            if (!_wasPlayingBeforeError || _loadInFlight || _usingBackup) return;
            final aheadNow = _bufferAheadSeconds();
            DiagLog.log(
              'sonda rete: ${up ? "ok" : "assente"} ahead=${aheadNow.toStringAsFixed(1)}s '
              'fermo da ${DateTime.now().difference(_bufferGrewAt).inSeconds}s',
            );
            if (!up) {
              _networkWasDown = true;
              _lastTrouble = DateTime.now();
              return;
            }
            if (_networkWasDown) {
              // Rete tornata dopo un'interruzione: se il vecchio flusso
              // riprende da solo (pause brevissime) non si tocca niente;
              // se dopo 1 s non e' cresciuto, ci si riconnette subito.
              _networkWasDown = false;
              final snapshot = _player.bufferedPosition;
              // Con poco buffer rimasto non c'e' tempo da perdere: si
              // riconnette subito (log reale: tagli da ~12 s arrivano qui con
              // ~2 s di audio, e il caricamento ne richiede 1 circa).
              final grace = aheadNow <= 5.0 ? Duration.zero : const Duration(seconds: 1);
              Timer(grace, () {
                if (!_wasPlayingBeforeError || _loadInFlight || _usingBackup) return;
                if (_player.bufferedPosition != snapshot) {
                  DiagLog.log("flusso ripreso da solo dopo l'interruzione");
                  return;
                }
                _handleStreamError(
                  'rete tornata ma flusso fermo: riconnessione anticipata',
                  delay: Duration.zero,
                );
              });
            } else if (aheadNow <= 3.5 ||
                DateTime.now().difference(_bufferGrewAt) >= const Duration(seconds: 8)) {
              // Con il cambio senza stacco riconnettersi presto non costa
              // niente: il vecchio audio continua fino al passaggio.
              _handleStreamError(
                'flusso fermo con rete disponibile: riconnessione anticipata',
                delay: Duration.zero,
              );
            }
          }));
        }
        if (state == ProcessingState.ready &&
            ahead <= 1.0 &&
            stagnant > const Duration(seconds: 4) &&
            !_networkWasDown) {
          _bufferGrewAt = now;
          _handleStreamError(
            'buffer quasi vuoto (${ahead.toStringAsFixed(1)} s) e fermo: riconnessione preventiva',
            delay: Duration.zero,
          );
          return;
        }
      }
    }

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
        unawaited(_fadeTo(1.0, _fadeInRecovery));
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
    if (nowPlaying == null) return;
    if (nowPlaying.artist == _lastArtist && nowPlaying.title == _lastTitle) {
      return;
    }
    _lastArtist = nowPlaying.artist;
    _lastTitle = nowPlaying.title;

    final item = MediaItem(
      id: RadioConfig.streamUrl,
      title: nowPlaying.title,
      artist: nowPlaying.subtitle(),
      artUri: Uri.parse(nowPlaying.cover),
      // Diretta: iOS/CarPlay tolgono barra di avanzamento e salti avanti/indietro.
      isLive: true,
      // Copertina originale: in auto e sulla lock screen resta quella standard
      // (niente effetto disco, scelta di Domenico); il disco e' solo nell'app.
      extras: {
        'cover': nowPlaying.cover,
        if (nowPlaying.songStartMs != null) 'songStartMs': nowPlaying.songStartMs,
        if (nowPlaying.durationSec != null) 'songDurationSec': nowPlaying.durationSec,
      },
    );
    // Il suono arriva con il ritardo del buffer (~30 s): titolo e copertina
    // compaiono con lo stesso ritardo. Un solo timer: l'ultimo cambio vince, e
    // un aggiornamento vecchio non puo' piu' coprirne uno nuovo.
    _metaTimer?.cancel();
    _metaTimer = null;
    final listening =
        _player.playing && _player.processingState == ProcessingState.ready;
    final delaySec = listening ? _bufferAheadSeconds() + _metadataOffsetSec : 0.0;
    void apply() {
      _baseItem = item;
      _pushMediaItem();
    }

    if (delaySec >= 1.5) {
      _metaTimer = Timer(Duration(milliseconds: (delaySec * 1000).round()), apply);
    } else {
      apply();
    }
  }

  /// Pubblica il brano corrente. La riga "album" (sotto l'artista su CarPlay e
  /// lock screen) riporta il nome della radio; il buffer non e' piu' scritto
  /// li' (Domenico l'ha voluto togliere): in auto resta il tasto con le
  /// tacche, sul telefono la barra sotto il tasto play.
  void _pushMediaItem() {
    // Il nome deve comparire in UN solo punto: se titolo o artista sono gia' il
    // nome della radio (jingle, nessun metadato) la riga album resta vuota.
    final alreadyShown = _baseItem.title == RadioConfig.stationName ||
        _baseItem.artist == RadioConfig.stationName;
    mediaItem.add(
      alreadyShown ? _baseItem : _baseItem.copyWith(album: RadioConfig.stationName),
    );
  }

  /// Tacche del buffer per il tasto della schermata "In riproduzione" di
  /// CarPlay (nativo): -1 quando non si sta ascoltando.
  void _sendBarsToCarPlay(int bars) {
    if (!_isIos) return;
    unawaited(_carPlayChannel
        .invokeMethod<void>('buffer', bars)
        .catchError((Object _) {}));
  }

  /// Storico recente dei secondi di buffer, per calmare la barra.
  final List<MapEntry<DateTime, double>> _aheadHistory = [];

  /// Su iOS bufferedPosition cresce a scatti (anche +14 s alla volta ogni ~20
  /// s), quindi il valore grezzo oscilla tra ~3 e ~15 s senza che l'audio
  /// abbia problemi. Per la barra si tiene il massimo degli ultimi 14 s e si
  /// mostra il valore grezzo solo quando e' davvero quasi zero (<= 1,5 s):
  /// cosi' la barra scende solo quando l'audio sta davvero finendo.
  double _calmAhead(double raw) {
    final now = DateTime.now();
    _aheadHistory.add(MapEntry(now, raw));
    _aheadHistory.removeWhere((e) => now.difference(e.key) > const Duration(seconds: 14));
    if (raw <= 1.5) return raw;
    // Rete assente o buffer fermo da oltre 8 s (interruzione vera): la barra
    // deve mostrare il calo reale, non il massimo recente.
    if (_networkWasDown || now.difference(_bufferGrewAt) > const Duration(seconds: 6)) return raw;
    var peak = raw;
    for (final e in _aheadHistory) {
      if (e.value > peak) peak = e.value;
    }
    return peak;
  }

  /// Porta il volume del player a `target` in `d`, a piccoli gradini. Ogni
  /// nuova chiamata annulla la precedente (_fadeGen). Salita con curva
  /// quadratica (parte molto piano), discesa lineare.
  Future<void> _fadeTo(double target, Duration d) async {
    final gen = ++_fadeGen;
    final from = _volume;
    final int steps = (d.inMilliseconds / 50).ceil().clamp(1, 100).toInt();
    for (var i = 1; i <= steps; i++) {
      if (gen != _fadeGen) return;
      final t = i / steps;
      final shaped = target > from ? t * t : t;
      final double v = (from + (target - from) * shaped).clamp(0.0, 1.0).toDouble();
      _volume = v;
      try {
        await _player.setVolume(v);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Discesa del volume prima di fermare il player (solo se sta suonando).
  Future<void> _fadeOutNow() async {
    if (!_player.playing) return;
    await _fadeTo(0.0, _fadeOutTime);
  }

  /// Dopo lo stop il volume torna a 1: il prossimo avvio lo azzera da solo.
  Future<void> _restoreVolume() async {
    _fadeGen++;
    _volume = 1.0;
    try {
      await _player.setVolume(1.0);
    } catch (_) {}
  }

  /// Spegne i tasti di salto/riavvolgimento nelle schermate di sistema
  /// (blocco, centro di controllo, CarPlay): in una radio dal vivo non servono.
  /// Va ripetuto a ogni cambio di stato perche' la libreria li riabilita.
  void _disableSkipCommands() {
    if (!_isIos) return;
    unawaited(_carPlayChannel.invokeMethod<void>('disableSkip').catchError((Object _) {}));
  }

  /// Rallentamento leggero, SOLO lato app (il server manda sempre a velocita'
  /// normale), SEMPRE acceso dall'avvio: la riproduzione va al 98,5%, cosi' il
  /// buffer cresce di 0,015 s al secondo fino a ~30 s (una galleria improvvisa
  /// non lascia il tempo di reagire: il margine va costruito prima). Si ferma
  /// al tetto e si riaccende da solo se il buffer scende (per esempio dopo un
  /// cambio di flusso). Mai durante interruzioni, cambi di flusso, caricamenti.
  void _updateSlowdown() {
    // DISATTIVATO (8/10, prova di Domenico su iPhone): a 0,985x la qualita'
    // audio peggiora in modo evidente (l'algoritmo di rallentamento di iOS non
    // conserva il suono). Il resto del buffer a 30 s (pause di sistema) resta.
    if (!_slowdownEnabled) {
      _resetSpeed();
      return;
    }
    final active = _player.playing &&
        _player.processingState == ProcessingState.ready &&
        !_usingBackup &&
        !_interrupted &&
        !_loadInFlight &&
        !_swapping &&
        !_waitingForCarPlay;
    if (!active) {
      _resetSpeed();
      return;
    }
    final ahead = _bufferAheadSeconds();
    final limit = _speed == _slowSpeed ? 30.0 : 29.0;
    final target = ahead < limit ? _slowSpeed : 1.0;
    if (target != _speed) _setSpeed(target);
  }

  void _setSpeed(double v) {
    if (v == _speed) return;
    final since = _activeSince;
    if (since != null) {
      final now = DateTime.now();
      _playedSeconds += now.difference(since).inMilliseconds / 1000.0 * _speed;
      _activeSince = now;
    }
    _speed = v;
    DiagLog.log(
      'velocita ${v.toStringAsFixed(2)}x (buffer ${_bufferAheadSeconds().toStringAsFixed(1)} s)',
    );
    unawaited(_player.setSpeed(v).catchError((Object e) {
      DiagLog.log('setSpeed errore: $e');
    }));
  }

  void _resetSpeed() {
    if (_speed != 1.0) _setSpeed(1.0);
  }

  /// Secondi di ascolto effettivo dall'ultimo caricamento, aggiornati in
  /// continuo (_playedSeconds cresce solo ai cambi di stato del player).
  double _playedNow() {
    var played = _playedSeconds;
    final since = _activeSince;
    if (since != null) {
      played += DateTime.now().difference(since).inMilliseconds / 1000.0 * _speed;
    }
    return played;
  }

  double _bufferAheadSeconds() {
    var played = _playedSeconds;
    final since = _activeSince;
    if (since != null) {
      played += DateTime.now().difference(since).inMilliseconds / 1000.0 * _speed;
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
    if (!active) _aheadHistory.clear();
    final ahead = active ? _calmAhead(_bufferAheadSeconds()) : 0.0;
    customEvent.add({'bufferAhead': ahead});
    var bars = -1;
    if (active) {
      bars = ahead <= 0.5 ? 0 : (ahead / 6).ceil().clamp(1, 5).toInt();
    }
    final now = DateTime.now();
    // Durante un'interruzione la barra in auto deve seguire il calo reale:
    // aggiornamento ogni 2 s invece di 6.
    final falling = _networkWasDown ||
        now.difference(_bufferGrewAt) > const Duration(seconds: 6);
    final minGap = Duration(seconds: falling ? 2 : 6);
    if (bars != _bufferBars && (bars <= 0 || now.difference(_lastBarsPush) > minGap)) {
      _bufferBars = bars;
      _lastBarsPush = now;
      _sendBarsToCarPlay(bars);
    }
  }

  void _clearBuffer() {
    _aheadHistory.clear();
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
    await _loadAndPlay(_liveUrl(), manualStart: true);
  }

  @override
  Future<void> pause() async {
    DiagLog.log('pause() richiesto');
    _wasPlayingBeforeError = false;
    _cancelRecoveryState();
    _stopLiveness();
    // Stesso comportamento di LiveOnlyPlayer.pause(): stop vero, non una
    // pausa che tiene il buffer, cosi' alla ripresa si riparte dal vivo.
    await _fadeOutNow();
    await _player.stop();
    await _restoreVolume();
    _publishState();
    _clearBuffer();
  }

  @override
  Future<void> stop() async {
    DiagLog.log('stop() richiesto');
    _wasPlayingBeforeError = false;
    _cancelRecoveryState();
    _stopLiveness();
    await _fadeOutNow();
    await _player.stop();
    await _restoreVolume();
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
    _playbackEventSub?.cancel();
    _becomingNoisySub?.cancel();
    _devicesChangedSub?.cancel();
    _interruptionSub?.cancel();
    _player.dispose();
  }
}
