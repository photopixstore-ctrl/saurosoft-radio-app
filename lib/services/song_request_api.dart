import 'dart:convert';
import 'package:http/http.dart' as http;

/// Brano richiedibile restituito dalla ricerca del sito.
class RequestableSong {
  final String requestId;
  final String artist;
  final String title;
  final String art;

  const RequestableSong({
    required this.requestId,
    required this.artist,
    required this.title,
    required this.art,
  });

  factory RequestableSong.fromJson(Map<String, dynamic> json) => RequestableSong(
        requestId: (json['request_id'] ?? '').toString(),
        artist: (json['artist'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        art: (json['art'] ?? '').toString(),
      );
}

/// Esito di una richiesta: il server risponde quasi sempre HTTP 200 anche in
/// caso di errore, quindi conta solo `success`; `message` e' gia' in italiano
/// e va mostrato cosi' com'e'.
class SongRequestResult {
  final bool success;
  final String message;

  const SongRequestResult({required this.success, required this.message});
}

/// Stesso endpoint pubblico usato dalla pagina /richiedi-canzone/ del sito.
/// Regole lato server (non aggirabili): 1 richiesta all'ora per IP (anche se
/// la richiesta poi fallisce), 2 ore per stessa canzone, dedica troncata a 200
/// caratteri; con nome e/o dedica parte l'annuncio vocale del DJ AI.
class SongRequestApi {
  static const String _base = 'https://www.saurosoftradio.it/api/song-request.php';
  static const int maxNameLength = 40;
  static const int maxDedicationLength = 200;

  /// Ricerca per sottostringa su "artista titolo" (minimo 2 caratteri,
  /// massimo 20 risultati). Lancia l'eccezione se la rete non risponde.
  Future<List<RequestableSong>> search(String query) async {
    final text = query.trim();
    if (text.length < 2) return const [];
    final uri = Uri.parse(_base).replace(queryParameters: {
      'action': 'search',
      'q': text,
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('Ricerca non disponibile (${response.statusCode})');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final results = (data['results'] as List<dynamic>? ?? const []);
    return results
        .map((e) => RequestableSong.fromJson(e as Map<String, dynamic>))
        .where((s) => s.requestId.isNotEmpty)
        .toList();
  }

  /// Invia UNA richiesta. Nessun tentativo automatico di ripetizione: il
  /// blocco di un'ora per IP scatta anche sulle richieste fallite.
  Future<SongRequestResult> submit({
    required String requestId,
    String name = '',
    String dedication = '',
  }) async {
    final body = <String, dynamic>{'request_id': requestId};
    final cleanName = name.trim();
    final cleanDedication = dedication.trim();
    if (cleanName.isNotEmpty) {
      body['sender_name'] = cleanName.length > maxNameLength
          ? cleanName.substring(0, maxNameLength)
          : cleanName;
    }
    if (cleanDedication.isNotEmpty) {
      body['dedication'] = cleanDedication.length > maxDedicationLength
          ? cleanDedication.substring(0, maxDedicationLength)
          : cleanDedication;
    }
    try {
      final response = await http
          .post(
            Uri.parse('$_base?action=submit'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return SongRequestResult(
        success: data['success'] == true,
        message: (data['message'] ?? 'Richiesta non accettata al momento.').toString(),
      );
    } catch (_) {
      return const SongRequestResult(
        success: false,
        message: 'Impossibile inviare la richiesta: controlla la connessione e riprova.',
      );
    }
  }
}
