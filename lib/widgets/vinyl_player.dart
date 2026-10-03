import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

const Color _accent = Color(0xFFFF7A1A);

/// Disco in vinile come sul sito: la copertina gira al centro di un disco
/// nero con i solchi e il braccio con la puntina si appoggia quando si
/// ascolta e si solleva in pausa. Solo telefono: CarPlay non consente grafica
/// libera alle app audio.
class VinylPlayer extends StatefulWidget {
  final String coverUrl;
  final bool playing;
  final double size;

  const VinylPlayer({
    super.key,
    required this.coverUrl,
    required this.playing,
    this.size = 250,
  });

  @override
  State<VinylPlayer> createState() => _VinylPlayerState();
}

class _VinylPlayerState extends State<VinylPlayer> with TickerProviderStateMixin {
  // Un giro ogni 3,6 s (il 33 giri vero ne fa uno ogni 1,8 s: troppo veloce
  // da guardare su uno schermo).
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));
  late final AnimationController _arm =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void initState() {
    super.initState();
    _apply();
  }

  @override
  void didUpdateWidget(VinylPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) _apply();
  }

  void _apply() {
    if (widget.playing) {
      // Il disco parte quando la puntina e' appoggiata.
      _arm.forward().whenComplete(() {
        if (mounted && widget.playing) _spin.repeat();
      });
    } else {
      _spin.stop();
      _arm.reverse();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _arm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        children: [
          RotationTransition(
            turns: _spin,
            child: RepaintBoundary(
              child: SizedBox(
                width: s,
                height: s,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(size: Size(s, s), painter: const _DiscPainter()),
                    ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: widget.coverUrl,
                        width: s * 0.6,
                        height: s * 0.6,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) =>
                            Container(width: s * 0.6, height: s * 0.6, color: Colors.white24),
                      ),
                    ),
                    Container(
                      width: s * 0.05,
                      height: s * 0.05,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF12151C),
                        border: Border.all(color: Colors.white54, width: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _arm,
              builder: (_, __) => CustomPaint(
                painter: _ArmPainter(Curves.easeInOut.transform(_arm.value)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Disco nero con solchi e riflessi.
class _DiscPainter extends CustomPainter {
  const _DiscPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF242424), Color(0xFF0B0B0B)],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    var alt = false;
    for (double g = r * 0.62; g < r * 0.97; g += 4) {
      groove.color = Colors.white.withOpacity(alt ? 0.10 : 0.04);
      canvas.drawCircle(c, g, groove);
      alt = !alt;
    }
    canvas.drawCircle(
      c,
      r * 0.97,
      Paint()
        ..shader = SweepGradient(
          colors: [
            Colors.transparent,
            Colors.white.withOpacity(0.14),
            Colors.transparent,
            Colors.transparent,
            Colors.white.withOpacity(0.14),
            Colors.transparent,
          ],
          stops: const [0.0, 0.12, 0.25, 0.5, 0.62, 0.75],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white10,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Braccio con puntina: `t` va da 0 (sollevato, fuori dal disco) a 1
/// (appoggiato sui solchi).
class _ArmPainter extends CustomPainter {
  final double t;
  const _ArmPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final pivot = Offset(s * 0.9, s * 0.1);
    final angle = (24 * t) * math.pi / 180;
    final dir = Offset(-math.sin(angle), math.cos(angle));
    final head = pivot + dir * (s * 0.75);
    final tail = pivot - dir * (s * 0.1);

    final shadow = Paint()
      ..color = Colors.black54
      ..strokeWidth = s * 0.026
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawLine(pivot + const Offset(3, 4), head + const Offset(3, 4), shadow);

    final arm = Paint()
      ..color = const Color(0xFFC9C9C9)
      ..strokeWidth = s * 0.02
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(tail, head, arm);

    // Contrappeso dietro il perno.
    canvas.drawLine(
      pivot - dir * (s * 0.05),
      tail,
      Paint()
        ..color = const Color(0xFF8E8E8E)
        ..strokeWidth = s * 0.05
        ..strokeCap = StrokeCap.round,
    );

    // Testina con la puntina.
    canvas.drawLine(
      head - dir * (s * 0.06),
      head + dir * (s * 0.015),
      Paint()
        ..color = const Color(0xFFE8E8E8)
        ..strokeWidth = s * 0.045
        ..strokeCap = StrokeCap.round,
    );

    // Perno.
    canvas.drawCircle(pivot, s * 0.045, Paint()..color = const Color(0xFF3A3A3A));
    canvas.drawCircle(
      pivot,
      s * 0.045,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white30,
    );
  }

  @override
  bool shouldRepaint(covariant _ArmPainter oldDelegate) => oldDelegate.t != t;
}

/// Equalizzatore SIMULATO: non e' collegato all'audio (un equalizzatore vero
/// non e' possibile con lo streaming su iOS), si muove soltanto mentre si
/// ascolta.
class SimulatedEqualizer extends StatefulWidget {
  final bool playing;
  final double height;

  const SimulatedEqualizer({super.key, required this.playing, this.height = 22});

  @override
  State<SimulatedEqualizer> createState() => _SimulatedEqualizerState();
}

class _SimulatedEqualizerState extends State<SimulatedEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t =
      AnimationController(vsync: this, duration: const Duration(seconds: 4));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _t.repeat();
  }

  @override
  void didUpdateWidget(SimulatedEqualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      widget.playing ? _t.repeat() : _t.stop();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: 140,
      child: AnimatedBuilder(
        animation: _t,
        builder: (_, __) => CustomPaint(
          painter: _EqPainter(_t.value, widget.playing),
        ),
      ),
    );
  }
}

class _EqPainter extends CustomPainter {
  final double t;
  final bool playing;
  const _EqPainter(this.t, this.playing);

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 18;
    final gap = 3.0;
    final w = (size.width - gap * (bars - 1)) / bars;
    final paint = Paint()..color = _accent;
    for (var i = 0; i < bars; i++) {
      var level = 0.12;
      if (playing) {
        final a = 0.5 + 0.5 * math.sin(2 * math.pi * t * (1 + i % 3) + i * 1.7);
        final b = 0.5 + 0.5 * math.sin(2 * math.pi * t * 2 + i * 0.9);
        level = 0.12 + 0.88 * a * (0.4 + 0.6 * b);
      }
      final h = size.height * level;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * (w + gap), size.height - h, w, h),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EqPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.playing != playing;
}
