import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/playlist.dart';

/// Stesso endpoint gia' usato da PlaylistApi.kt.
class PlaylistApi {
  static const String _playlistUrl = 'https://www.saurosoftradio.it/api/playlist.php';

  Future<RispostaPlaylist?> fetch({String? data}) async {
    final uri = Uri.parse(data != null ? '$_playlistUrl?data=$data' : _playlistUrl);
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return RispostaPlaylist.fromJson(json);
      }
    } catch (_) {}
    return null;
  }
}
