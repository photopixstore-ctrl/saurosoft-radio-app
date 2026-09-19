/// ============================================================
/// RADIO CONFIG - UNICO FILE DA MODIFICARE PER OGNI CLIENTE
/// ============================================================
/// Stesso concetto di RadioConfig.kt nella versione Android nativa:
/// per rebrandare l'app con un altro cliente radio, basta cambiare
/// i valori qui sotto. Nessun altro file va toccato.
/// ============================================================
class RadioConfig {
  static const String stationName = 'Saurosoft Radio';
  static const String tagline = 'Le migliori hits di ieri e di oggi';
  static const String website = 'https://www.saurosoftradio.it';

  // URL dello streaming audio diretto (AzuraCast su VPS Contabo,
  // sostituisce il vecchio host nr11.newradio.it dismesso con la migrazione)
  static const String streamUrl =
      'https://streaming.saurosoftradio.it/listen/saurosoft_radio/radio.mp3';

  // File mp3 di riserva ospitato su Serverplan (hosting saurosoftradio.it),
  // indipendente dalla VPS Contabo che ospita AzuraCast/Icecast: se il live
  // continua a fallire, il player ci si aggancia esplicitamente finche' il
  // live non torna disponibile. Aggiornato mensilmente lato server con i
  // brani piu' ascoltati (vedi memoria "azuracast-saurosoft-radio-infra").
  static const String backupStreamUrl =
      'https://www.saurosoftradio.it/wp-content/uploads/saurosoft-radio-backup.mp3';

  // Endpoint che restituisce i metadati live (title, artist, year, cover)
  static const String metadataUrl = 'https://www.saurosoftradio.it/api/current.php';

  // Base per gli sfondi stagionali (stesso set gia' usato nella skill Alexa
  // e nell'app Android): sono immagini remote, non incluse nel progetto.
  static const String sfondiBaseUrl = 'https://www.saurosoftradio.it/loghiradio/';

  /// Restituisce l'URL dello sfondo stagionale in base al mese corrente.
  static String sfondoStagionale() {
    final mese = DateTime.now().month;
    if (mese >= 3 && mese <= 5) return '${sfondiBaseUrl}primavera.jpg';
    if (mese >= 6 && mese <= 8) return '${sfondiBaseUrl}estate.jpg';
    if (mese >= 9 && mese <= 11) return '${sfondiBaseUrl}autunno.jpg';
    return '${sfondiBaseUrl}inverno.jpg';
  }

  // Logo di fallback quando current.php non restituisce una copertina valida
  static const String fallbackLogoUrl =
      'https://www.saurosoft.it/radio/loghiradio/logoradio468x360.jpg';

  // Identificativi app - quelli gia' generati con `flutter create --org it.photopix`.
  // NOTA: sono diversi dal package "it.saurosoft.radio" dell'app Android nativa
  // esistente. Questo va bene se questa e' una pubblicazione nuova/separata;
  // se invece un giorno vuoi che questa app SOSTITUISCA quella nativa sul Play
  // Store (stesso annuncio, aggiornamento), l'applicationId Android dovra'
  // combaciare esattamente con "it.saurosoft.radio" - fammelo sapere, e' una
  // modifica da fare prima di pubblicare, non dopo.
  static const String androidApplicationId = 'it.photopix.saurosoft_radio';
  static const String iosBundleId = 'it.photopix.saurosoft_radio';

  // Intervallo di polling dei metadati (secondi) - stesso valore usato in Android
  static const int metadataPollIntervalSeconds = 12;

  // Testo mostrato nella sezione "Info" dell'app
  static const String infoText =
      'App sviluppata da Photopix\nwww.photopix.it\nvia Filzi 7, 38060 Nomi (TN)\ntel. 0464.350707';
  static const String infoLogoUrl =
      'https://www.photopix.it/sito/wp-content/uploads/2019/11/logofooter2.png';
}
