import 'dart:io';
import 'package:flutter/material.dart';

/// Pulsante AirPlay (nativo di Apple) per trasmettere l'audio verso
/// Apple TV/casse compatibili. Visibile solo su iOS: nel mondo Apple
/// non serve Chromecast, ed e' stato rimosso per questa versione.
class CastAirplayButton extends StatelessWidget {
  const CastAirplayButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: UiKitView(viewType: 'saurosoft_airplay_button'),
      );
    }
    return const SizedBox.shrink();
  }
}
