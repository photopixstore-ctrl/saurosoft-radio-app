import 'dart:convert';
import 'package:http/http.dart' as http;
import '../radio_config.dart';
import '../models/now_playing.dart';

/// Legge artista/titolo dal current.php, replicando la logica gia'
/// usata nella skill Alexa: aggiunge un timestamp (?_a=) per evitare
/// che eventuali cache intermedie restituiscano dati vecchi.
class MetadataService {
  Future<NowPlaying> fetchNowPlaying() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final uri = Uri.parse('${RadioConfig.metadataUrl}?_a=$timestamp');

    try {
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return NowPlaying.fromJson(data);
      }
    } catch (_) {
      // In caso di errore di rete/timeout si mantiene lo stato precedente
    }
    return NowPlaying.empty();
  }
}
