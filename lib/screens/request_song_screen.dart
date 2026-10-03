import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../services/song_request_api.dart';

/// Richiesta canzone a mano: cerca un brano nel catalogo della radio e lo
/// invia come sul sito (/richiedi-canzone/). Il server consente una
/// richiesta all'ora per IP, quindi si chiede sempre conferma prima di
/// inviare e non si ritenta mai da soli.
class RequestSongScreen extends StatefulWidget {
  const RequestSongScreen({super.key});

  @override
  State<RequestSongScreen> createState() => _RequestSongScreenState();
}

class _RequestSongScreenState extends State<RequestSongScreen> {
  static const String _hint = 'Scrivi almeno 2 lettere di artista o titolo.';

  final SongRequestApi _api = SongRequestApi();
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<RequestableSong> _results = const [];
  bool _loading = false;
  bool _sending = false;
  String? _message = _hint;
  int _searchGen = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(text));
  }

  Future<void> _search(String text) async {
    final query = text.trim();
    if (query.length < 2) {
      _searchGen++;
      setState(() {
        _results = const [];
        _loading = false;
        _message = _hint;
      });
      return;
    }
    final gen = ++_searchGen;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final results = await _api.search(query);
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _results = results;
        _loading = false;
        _message = results.isEmpty ? 'Nessun brano trovato. Prova con altre parole.' : null;
      });
    } catch (_) {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _results = const [];
        _loading = false;
        _message = 'Ricerca non riuscita: controlla la connessione e riprova.';
      });
    }
  }

  Future<void> _confirm(RequestableSong song) async {
    if (_sending) return;
    final nameController = TextEditingController();
    final dedicationController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Richiedere questo brano?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(song.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              Text(song.artist),
              const SizedBox(height: 12),
              const Text(
                'Puoi inviare una sola richiesta all\'ora. Il brano va in onda dopo circa 5-10 minuti.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                maxLength: SongRequestApi.maxNameLength,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Il tuo nome (facoltativo)'),
              ),
              TextField(
                controller: dedicationController,
                maxLength: SongRequestApi.maxDedicationLength,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Dedica (facoltativa)'),
              ),
              const SizedBox(height: 4),
              const Text(
                'Con nome o dedica, la voce della radio li leggera\' in onda prima del brano.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Invia richiesta'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _sending = true);
    final result = await _api.submit(
      requestId: song.requestId,
      name: nameController.text,
      dedication: dedicationController.text,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(result.success ? 'Richiesta inviata' : 'Richiesta non inviata'),
        content: Text(result.message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result.success && mounted) Navigator.of(context).pop();
  }

  Widget _cover(RequestableSong song) {
    const size = 48.0;
    final placeholder = Container(
      width: size,
      height: size,
      color: Colors.white12,
      child: const Icon(Icons.music_note, color: Colors.white54),
    );
    if (song.art.isEmpty) return placeholder;
    return CachedNetworkImage(
      imageUrl: song.art,
      width: size,
      height: size,
      fit: BoxFit.cover,
      errorWidget: (_, __, ___) => placeholder,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12151C),
      appBar: AppBar(
        title: const Text('Richiedi una canzone'),
        backgroundColor: const Color(0xFF12151C),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Artista o titolo',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          _search('');
                        },
                      ),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _message!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, index) {
                final song = _results[index];
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: _cover(song),
                  ),
                  title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.send, size: 18),
                  onTap: _sending ? null : () => _confirm(song),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
