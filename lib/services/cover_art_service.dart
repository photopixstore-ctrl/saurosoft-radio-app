import 'dart:convert';
import 'package:http/http.dart' as http;
import '../radio_config.dart';

/// Cerca la cover art su iTunes, poi su Deezer come fallback,
/// infine ripiega sul logo statico della stazione.
/// Stessa cascata gia' implementata in current.php per Alexa.
class CoverArtService {
  Future<String> findCoverArt({
    required String artist,
    required String title,
  }) async {
    final query = '$artist $title'.trim();
    if (query.isEmpty) return RadioConfig.logoAssetPath;

    final itunesUrl = await _searchItunes(query);
    if (itunesUrl != null) return itunesUrl;

    final deezerUrl = await _searchDeezer(query);
    if (deezerUrl != null) return deezerUrl;

    return RadioConfig.logoAssetPath;
  }

  Future<String?> _searchItunes(String query) async {
    try {
      final uri = Uri.https('itunes.apple.com', '/search', {
        'term': query,
        'media': 'music',
        'limit': '1',
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          final artwork = results.first['artworkUrl100'] as String?;
          if (artwork != null) {
            // Richiede una cover a risoluzione piu' alta (600x600 invece di 100x100)
            return artwork.replaceAll('100x100', '600x600');
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _searchDeezer(String query) async {
    try {
      final uri = Uri.https('api.deezer.com', '/search', {'q': query});
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = data['data'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          final album = results.first['album'] as Map<String, dynamic>?;
          final cover = album?['cover_big'] as String?;
          if (cover != null) return cover;
        }
      }
    } catch (_) {}
    return null;
  }
}
