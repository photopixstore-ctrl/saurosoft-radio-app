import 'dart:convert';
import 'dart:io' show HttpDate;
import 'package:http/http.dart' as http;
import '../radio_config.dart';
import '../models/now_playing.dart';

/// Legge titolo/artista/copertina da current.php - stesso endpoint
/// gia' usato dalla skill Alexa e dall'app Android (NowPlaying.kt).
/// La copertina arriva gia' risolta dal server: qui non serve fare
/// nessuna ricerca aggiuntiva su iTunes/Deezer lato app.
class MetadataService {
  Future<NowPlaying?> fetchNowPlaying() async {
    // Prima il server radio (ha anche la canzone successiva); se non risponde
    // si ripiega su current.php del sito (senza "Poi:").
    final primary = await _fetch(RadioConfig.nowPlayingUrl);
    if (primary != null) return primary;
    return _fetch(RadioConfig.metadataUrl, fallback: true);
  }

  Future<NowPlaying?> _fetch(String baseUrl, {bool fallback = false}) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final uri = Uri.parse('$baseUrl?t=$timestamp');

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        int? serverNowSec;
        final date = response.headers['date'];
        if (date != null) {
          try {
            serverNowSec = HttpDate.parse(date).millisecondsSinceEpoch ~/ 1000;
          } catch (_) {}
        }
        return NowPlaying.fromJson(data,
            serverNowSec: serverNowSec, fromFallback: fallback);
      }
    } catch (_) {
      // In caso di errore di rete/timeout si mantiene lo stato precedente
    }
    // null = nessun dato nuovo: chi chiama tiene il titolo che c'era (prima si
    // sostituiva con il titolo di ripiego, e la copertina restava ferma).
    return null;
  }
}
