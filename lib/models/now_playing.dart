import '../radio_config.dart';

/// Rappresenta il brano attualmente in onda, letto da current.php.
/// Stessa struttura dati di NowPlaying.kt.
class NowPlaying {
  final String title;
  final String artist;
  final String year;
  final String cover;

  /// Durata del brano in secondi e istante (ora del telefono, ms) in cui e'
  /// iniziato: servono al disco in vinile per muovere il braccio dall'esterno
  /// verso il centro durante il brano. Null se il server non li fornisce.
  final int? durationSec;
  final int? songStartMs;

  /// Canzone successiva (campi next_* di current.php). Vuoti se il server non
  /// la conosce o non e' sicuro (spot/jingle): in quel caso niente "Poi:".
  final String nextTitle;
  final String nextArtist;
  final String nextYear;
  final String nextCover;

  /// True se il dato viene dal ripiego (current.php), che non conosce la
  /// canzone successiva.
  final bool fromFallback;

  const NowPlaying({
    required this.title,
    required this.artist,
    required this.year,
    required this.cover,
    this.durationSec,
    this.songStartMs,
    this.nextTitle = '',
    this.nextArtist = '',
    this.nextYear = '',
    this.nextCover = '',
    this.fromFallback = false,
  });

  factory NowPlaying.fallback() => NowPlaying(
        title: RadioConfig.stationName,
        artist: '',
        year: '',
        cover: RadioConfig.fallbackLogoUrl,
      );

  /// [serverNowSec]: ora del server (header HTTP Date) per allineare l'inizio
  /// del brano all'orologio del telefono, anche se non sono sincronizzati.
  factory NowPlaying.fromJson(Map<String, dynamic> json,
      {int? serverNowSec, bool fromFallback = false}) {
    final cover = (json['cover'] ?? '').toString();
    final duration = json['duration'] is num ? (json['duration'] as num).toInt() : null;
    final startedAt = json['started_at'] is num ? (json['started_at'] as num).toInt() : null;
    final updated = json['updated'] is num ? (json['updated'] as num).toInt() : null;
    int? songStartMs;
    final now = serverNowSec ?? updated;
    if (duration != null && duration > 0 && startedAt != null && now != null) {
      // Pochi secondi di scarto tra orologio del server e started_at sono
      // normali all'inizio del brano: si tratta come "appena iniziato".
      final elapsedSec = now - startedAt < 0 ? 0 : now - startedAt;
      if (now - startedAt >= -5 && elapsedSec <= duration + 30) {
        songStartMs = DateTime.now().millisecondsSinceEpoch - elapsedSec * 1000;
      }
    }
    return NowPlaying(
      durationSec: songStartMs != null ? duration : null,
      songStartMs: songStartMs,
      // Titolo vuoto (stazione ferma o riavvio): si mostra il nome della radio.
      title: ((json['title'] ?? '').toString().trim().isEmpty)
          ? RadioConfig.stationName
          : json['title'].toString(),
      artist: (json['artist'] ?? '').toString(),
      year: (json['year'] ?? '').toString(),
      cover: cover.isEmpty ? RadioConfig.fallbackLogoUrl : cover,
      nextTitle: (json['next_title'] ?? '').toString().trim(),
      nextArtist: (json['next_artist'] ?? '').toString().trim(),
      nextYear: (json['next_year'] ?? '').toString().trim(),
      nextCover: (json['next_cover'] ?? '').toString().trim(),
      fromFallback: fromFallback,
    );
  }

  /// Artista della canzone successiva con l'anno, come nell'elenco CarPlay.
  String nextSubtitle() {
    if (nextArtist.isEmpty) return '';
    return nextYear.isNotEmpty ? '$nextArtist ($nextYear)' : nextArtist;
  }

  /// Sottotitolo pronto per la UI: "Artista (Anno)" oppure il nome
  /// stazione se manca l'artista - stessa logica di NowPlaying.kt.
  String subtitle() {
    if (artist.isEmpty) return RadioConfig.stationName;
    return year.isNotEmpty ? '$artist ($year)' : artist;
  }
}
