import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'diag_log.dart';

/// Compone la copertina dentro un disco in vinile (solchi, buco centrale,
/// riflesso) e la salva come PNG, per darla a CarPlay/lock screen come
/// immagine statica. CarPlay non consente grafica libera ne' animazioni alle
/// app audio: la copertina e' l'unico punto dove l'effetto "disco" e'
/// possibile. Lato telefono resta la copertina originale (extras['cover']).
class DiscArtwork {
  // Mai oltre 500 px: regola per le copertine dell'app.
  static const int _size = 500;
  static const int _maxCached = 20;
  static final Map<String, Uri> _cache = {};

  /// Ritorna il file del disco, oppure null se qualcosa non va (rete,
  /// immagine non valida, GPU non disponibile in background): in quel caso si
  /// usa la copertina normale.
  static Future<Uri?> compose(String coverUrl) async {
    final cached = _cache[coverUrl];
    if (cached != null && File.fromUri(cached).existsSync()) return cached;
    try {
      final response = await http
          .get(Uri.parse(coverUrl))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;

      final codec = await ui.instantiateImageCodec(
        response.bodyBytes,
        targetWidth: 360,
      );
      final cover = (await codec.getNextFrame()).image;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, _size.toDouble(), _size.toDouble()),
      );
      _paintDisc(canvas, cover);
      final image = await recorder
          .endRecording()
          .toImage(_size, _size)
          .timeout(const Duration(seconds: 8));
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;

      final file = File(
        '${Directory.systemTemp.path}/saurosoft_disc_${coverUrl.hashCode}.png',
      );
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      final uri = Uri.file(file.path);
      _remember(coverUrl, uri);
      return uri;
    } catch (e) {
      DiagLog.log('disco copertina non creato: ${e.runtimeType} $e');
      return null;
    }
  }

  static void _remember(String key, Uri uri) {
    _cache[key] = uri;
    while (_cache.length > _maxCached) {
      final oldest = _cache.keys.first;
      final old = _cache.remove(oldest);
      if (old != null) {
        try {
          File.fromUri(old).deleteSync();
        } catch (_) {}
      }
    }
  }

  static void _paintDisc(ui.Canvas canvas, ui.Image cover) {
    const s = _size / 2.0;
    const center = ui.Offset(s, s);

    // Disco nero con leggero degradé.
    canvas.drawCircle(
      center,
      s,
      ui.Paint()
        ..shader = ui.Gradient.radial(
          center,
          s,
          const [ui.Color(0xFF242424), ui.Color(0xFF0B0B0B)],
        ),
    );

    // Solchi sottili.
    final groove = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1;
    var alt = false;
    for (double r = s * 0.66; r < s * 0.97; r += 5) {
      groove.color = ui.Color.fromARGB(alt ? 26 : 12, 255, 255, 255);
      canvas.drawCircle(center, r, groove);
      alt = !alt;
    }

    // Riflessi opposti, come la luce su un vinile vero.
    canvas.drawCircle(
      center,
      s * 0.97,
      ui.Paint()
        ..shader = ui.Gradient.sweep(
          center,
          const [
            ui.Color(0x00FFFFFF),
            ui.Color(0x26FFFFFF),
            ui.Color(0x00FFFFFF),
            ui.Color(0x00FFFFFF),
            ui.Color(0x26FFFFFF),
            ui.Color(0x00FFFFFF),
          ],
          const [0.0, 0.12, 0.25, 0.5, 0.62, 0.75],
          ui.TileMode.clamp,
          0,
          math.pi * 2,
        ),
    );

    // Copertina al centro (ritaglio quadrato centrato, poi tondo).
    final coverRadius = s * 0.60;
    final side = math.min(cover.width, cover.height).toDouble();
    final src = ui.Rect.fromLTWH(
      (cover.width - side) / 2,
      (cover.height - side) / 2,
      side,
      side,
    );
    canvas.save();
    canvas.clipPath(
      ui.Path()..addOval(ui.Rect.fromCircle(center: center, radius: coverRadius)),
    );
    canvas.drawImageRect(
      cover,
      src,
      ui.Rect.fromCircle(center: center, radius: coverRadius),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    canvas.restore();
    canvas.drawCircle(
      center,
      coverRadius,
      ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = const ui.Color(0xAA000000),
    );

    // Buco centrale.
    canvas.drawCircle(center, s * 0.05, ui.Paint()..color = const ui.Color(0xFF12151C));
    canvas.drawCircle(
      center,
      s * 0.05,
      ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const ui.Color(0x88FFFFFF),
    );
  }
}
