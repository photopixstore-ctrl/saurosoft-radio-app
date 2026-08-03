class GiornoTab {
  final String data;
  final String etichetta;
  const GiornoTab({required this.data, required this.etichetta});

  factory GiornoTab.fromJson(Map<String, dynamic> json) => GiornoTab(
        data: (json['data'] ?? '').toString(),
        etichetta: (json['etichetta'] ?? '').toString(),
      );
}

class VoceStorico {
  final String ora;
  final String artist;
  final String title;
  const VoceStorico({required this.ora, required this.artist, required this.title});

  factory VoceStorico.fromJson(Map<String, dynamic> json) => VoceStorico(
        ora: (json['ora'] ?? '').toString(),
        artist: (json['artist'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
      );
}

class RispostaPlaylist {
  final List<GiornoTab> giorni;
  final String dataSelezionata;
  final List<VoceStorico> canzoni;

  const RispostaPlaylist({
    required this.giorni,
    required this.dataSelezionata,
    required this.canzoni,
  });

  factory RispostaPlaylist.fromJson(Map<String, dynamic> json) {
    final giorniList = (json['giorni'] as List<dynamic>? ?? [])
        .map((g) => GiornoTab.fromJson(g as Map<String, dynamic>))
        .toList();
    final canzoniList = (json['canzoni'] as List<dynamic>? ?? [])
        .map((c) => VoceStorico.fromJson(c as Map<String, dynamic>))
        .toList();
    return RispostaPlaylist(
      giorni: giorniList,
      dataSelezionata: (json['data_selezionata'] ?? '').toString(),
      canzoni: canzoniList,
    );
  }
}
