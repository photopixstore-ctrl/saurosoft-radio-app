import 'dart:io';

/// Log diagnostico persistente (file nella cartella temporanea dell'app,
/// ultimi 5 giorni: le righe piu' vecchie si cancellano da sole; come
/// sicurezza il file non supera 10 MB) consultabile e condivisibile dalla finestra
/// "Informazioni sviluppatore". Serve a capire dai dati reali cosa fa il
/// player quando lo streaming non riparte, invece di indovinare.
class DiagLog {
  static const int _maxBytes = 10 * 1024 * 1024;
  static const Duration _retention = Duration(days: 5);
  static DateTime _lastPrune = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _maxDumpLines = 700;
  static final List<String> _memory = [];
  static File? _file;

  static File _logFile() {
    return _file ??= File('${Directory.systemTemp.path}/saurosoft_radio_diag.log');
  }

  static void log(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    _memory.add(line);
    if (_memory.length > 500) _memory.removeAt(0);
    try {
      final file = _logFile();
      final now = DateTime.now();
      // Cancella le righe piu' vecchie di 5 giorni: a ogni avvio e poi ogni 6 ore.
      if (file.existsSync() && now.difference(_lastPrune) > const Duration(hours: 6)) {
        _lastPrune = now;
        _pruneOld(file, now);
      }
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        final lines = file.readAsLinesSync();
        file.writeAsStringSync('${lines.sublist(lines.length ~/ 2).join('\n')}\n');
      }
      file.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // Il log non deve mai poter rompere la riproduzione.
    }
  }

  static void _pruneOld(File file, DateTime now) {
    // Ogni riga inizia con l'ora in formato ISO (aaaa-mm-ggThh:mm:ss...), quindi
    // il confronto tra testi equivale al confronto tra date.
    final cutoff = now.subtract(_retention).toIso8601String();
    final lines = file.readAsLinesSync();
    var first = 0;
    while (first < lines.length && lines[first].compareTo(cutoff) < 0) {
      first++;
    }
    if (first > 0) {
      file.writeAsStringSync(
        first >= lines.length ? '' : '${lines.sublist(first).join('\n')}\n',
      );
    }
  }

  static String dump() {
    try {
      final file = _logFile();
      if (file.existsSync()) {
        final lines = file.readAsLinesSync();
        final start = lines.length > _maxDumpLines ? lines.length - _maxDumpLines : 0;
        return lines.sublist(start).join('\n');
      }
    } catch (_) {}
    return _memory.join('\n');
  }
}
