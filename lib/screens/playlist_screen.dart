import 'dart:async';
import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/playlist_api.dart';

const _refreshInterval = Duration(seconds: 15);

/// Storico canzoni trasmesse, con tab per i giorni precedenti.
/// Equivalente Flutter di PlaylistScreen.kt.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  final PlaylistApi _api = PlaylistApi();
  RispostaPlaylist? _risposta;
  String? _giornoSelezionato;
  bool _caricando = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _carica();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _carica(mostraCaricamento: false));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _carica({bool mostraCaricamento = true}) async {
    if (mostraCaricamento) setState(() => _caricando = true);
    final risposta = await _api.fetch(data: _giornoSelezionato);
    if (!mounted) return;
    setState(() {
      if (risposta != null) _risposta = risposta;
      _caricando = false;
    });
  }

  void _selezionaGiorno(String data) {
    setState(() => _giornoSelezionato = data);
    _carica();
  }

  @override
  Widget build(BuildContext context) {
    final risposta = _risposta;

    return Scaffold(
      backgroundColor: const Color(0xFF12151C),
      appBar: AppBar(
        backgroundColor: const Color(0xFF12151C),
        title: const Text('Playlist', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          if (risposta != null)
            SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: risposta.giorni.map((giorno) {
                  final selezionato = giorno.data == risposta.dataSelezionata;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: InkWell(
                      onTap: () => _selezionaGiorno(giorno.data),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selezionato ? const Color(0xFFFF7A1A) : Colors.transparent,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          giorno.etichetta,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: selezionato ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          const Divider(color: Colors.white10, height: 1),
          Expanded(child: _buildContenuto(risposta)),
        ],
      ),
    );
  }

  Widget _buildContenuto(RispostaPlaylist? risposta) {
    if (_caricando) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    if (risposta == null) {
      return Center(
        child: Text('Impossibile caricare la playlist.',
            style: TextStyle(color: Colors.white.withOpacity(0.7))),
      );
    }
    if (risposta.canzoni.isEmpty) {
      return Center(
        child: Text('Nessuna canzone registrata per questo giorno.',
            style: TextStyle(color: Colors.white.withOpacity(0.7))),
      );
    }
    return ListView.separated(
      itemCount: risposta.canzoni.length,
      separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
      itemBuilder: (context, index) {
        final voce = risposta.canzoni[index];
        final brano = '${voce.artist} - ${voce.title}'.replaceFirst(RegExp(r'^[\s-]+'), '');
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(voce.ora,
                  style: const TextStyle(color: Color(0xFFFF7A1A), fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(brano, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
        );
      },
    );
  }
}
