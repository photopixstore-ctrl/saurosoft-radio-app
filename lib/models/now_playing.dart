import '../radio_config.dart';

/// Rappresenta il brano attualmente in onda, letto da current.php.
/// Stessa struttura dati di NowPlaying.kt.
class NowPlaying {
  final String title;
  final String artist;
  final String year;
  final String cover;

  const NowPlaying({
    required this.title,
    required this.artist,
    required this.year,
    required this.cover,
  });

  factory NowPlaying.fallback() => NowPlaying(
        title: RadioConfig.stationName,
        artist: '',
        year: '',
        cover: RadioConfig.fallbackLogoUrl,
      );

  factory NowPlaying.fromJson(Map<String, dynamic> json) {
    final cover = (json['cover'] ?? '').toString();
    return NowPlaying(
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
