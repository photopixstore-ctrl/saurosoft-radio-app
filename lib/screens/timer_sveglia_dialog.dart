import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../services/alarm_service.dart';
import '../services/radio_audio_handler.dart';

/// Sleep timer + sveglia in un'unica finestra, stesso concetto di
/// TimerSvegliaDialog.kt.
class TimerSvegliaDialog extends StatelessWidget {
  final AudioHandler audioHandler;

  const TimerSvegliaDialog({super.key, required this.audioHandler});

  void _mostraMessaggio(BuildContext context, String testo) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(testo)));
  }

  Future<void> _impostaSveglia(BuildContext context) async {
    final now = TimeOfDay.now();
    final scelto = await showTimePicker(context: context, initialTime: now);
    if (scelto == null) return;
    await AlarmService.programma(scelto.hour, scelto.minute);
    if (context.mounted) {
      _mostraMessaggio(
        context,
        'Sveglia impostata per le ${scelto.hour.toString().padLeft(2, '0')}:${scelto.minute.toString().padLeft(2, '0')}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Timer e sveglia'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Sleep timer', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text('Ferma la riproduzione dopo il tempo scelto.',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [15, 30, 45, 60].map((minuti) {
              return OutlinedButton(
                onPressed: () {
                  audioHandler.customAction(
                    RadioAudioHandler.actionSetSleepTimer,
                    {'minutes': minuti},
                  );
                  _mostraMessaggio(context, 'Timer impostato: $minuti min');
                },
                child: Text('${minuti}m'),
              );
            }).toList(),
          ),
          TextButton(
            onPressed: () {
              audioHandler.customAction(RadioAudioHandler.actionCancelSleepTimer);
              _mostraMessaggio(context, 'Timer annullato');
            },
            child: const Text('Annulla timer'),
          ),
          const Divider(),
          const Text('Sveglia', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text(
            "All'orario scelto arriva una notifica: toccandola si apre "
            "l'app e parte la radio.",
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ElevatedButton(
                onPressed: () => _impostaSveglia(context),
                child: const Text('Imposta sveglia'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await AlarmService.annulla();
                  _mostraMessaggio(context, 'Sveglia annullata');
                },
                child: const Text('Annulla'),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Chiudi'),
        ),
      ],
    );
  }
}
