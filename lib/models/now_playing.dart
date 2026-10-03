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

  const NowPlaying({
    required this.title,
    required this.artist,
    required this.year,
    required this.cover,
    this.durationSec,
    this.songStartMs,
  });

  factory NowPlaying.fallback() => NowPlaying(
        title: RadioConfig.stationName,
        artist: '',
        year: '',
        cover: RadioConfig.fallbackLogoUrl,
      );

  /// [serverNowSec]: ora del server (header HTTP Date) per allineare l'inizio
  /// del brano all'orologio del telefono, anche se non sono sincronizzati.
  factory NowPlaying.fromJson(Map<String, dynamic> json, {int? serverNowSec}) {
    final cover = (json['cover'] ?? '').toString();
    final duration = json['duration'] is num ? (json['duration'] as num).toInt() : null;
    final startedAt = json['started_at'] is num ? (json['started_at'] as num).toInt() : null;
    final updated = json['updated'] is num ? (json['updated'] as num).toInt() : null;
    int? songStartMs;
    final now = serverNowSec ?? updated;
    if (duration != null && duration > 0 && startedAt != null && now != null) {
      final elapsedSec = now - startedAt;
      if (elapsedSec >= 0 && elapsedSec <= duration + 30) {
        songStartMs = DateTime.now().millisecondsSinceEpoch - elapsedSec * 1000;
      }
    }
    return NowPlaying(
      durationSec: songStartMs != null ? duration : null,
      songStartMs: songStartMs,
      title: (json['title'] ?? RadioConfig.stationName).toString(),
      artist: (json['artist'] ?? '').toString(),
      year: (json['year'] ?? '').toString(),
      cover: cover.isEmpty ? RadioConfig.fallbackLogoUrl : cover,
    );
  }

  /// Sottotitolo pronto per la UI: "Artista (Anno)" oppure il nome
  /// stazione se manca l'artista - stessa logica di NowPlaying.kt.
  String subtitle() {
    if (artist.isEmpty) return RadioConfig.stationName;
    return year.isNotEmpty ? '$artist ($year)' : artist;
  }
}
