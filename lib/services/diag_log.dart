import 'dart:io';

/// Log diagnostico persistente (file nella cartella temporanea dell'app,
/// ultime ~200 KB) consultabile e condivisibile dalla finestra
/// "Informazioni sviluppatore". Serve a capire dai dati reali cosa fa il
/// player quando lo streaming non riparte, invece di indovinare.
class DiagLog {
  static const int _maxBytes = 200 * 1024;
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
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        final lines = file.readAsLinesSync();
        file.writeAsStringSync('${lines.sublist(lines.length ~/ 2).join('\n')}\n');
      }
      file.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // Il log non deve mai poter rompere la riproduzione.
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
