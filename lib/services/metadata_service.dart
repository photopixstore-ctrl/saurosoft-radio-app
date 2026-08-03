import 'dart:convert';
import 'package:http/http.dart' as http;
import '../radio_config.dart';
import '../models/now_playing.dart';

/// Legge titolo/artista/copertina da current.php - stesso endpoint
/// gia' usato dalla skill Alexa e dall'app Android (NowPlaying.kt).
/// La copertina arriva gia' risolta dal server: qui non serve fare
/// nessuna ricerca aggiuntiva su iTunes/Deezer lato app.
class MetadataService {
  Future<NowPlaying> fetchNowPlaying() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final uri = Uri.parse('${RadioConfig.metadataUrl}?t=$timestamp');

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return NowPlaying.fromJson(data);
      }
    } catch (_) {
      // In caso di errore di rete/timeout si mantiene lo stato precedente
    }
    return NowPlaying.fallback();
  }
}
