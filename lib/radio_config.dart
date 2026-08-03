/// ============================================================
/// RADIO CONFIG - UNICO FILE DA MODIFICARE PER OGNI CLIENTE
/// ============================================================
/// Stesso concetto di RadioConfig.kt nella versione Android nativa:
/// per rebrandare l'app per un nuovo cliente radio, basta cambiare
/// i valori qui sotto. Nessun altro file va toccato.
/// ============================================================
class RadioConfig {
  // Nome stazione mostrato in app, notifiche, lock screen, Android Auto, CarPlay
  static const String stationName = 'Saurosoft Radio';

  // URL diretto dello stream audio (mp3/aac) - SOSTITUIRE con quello reale usato nell'app Android
  static const String streamUrl = 'https://TODO-inserisci-url-stream-reale';

  // Endpoint current.php che restituisce artista/titolo in tempo reale - stesso usato per Alexa
  static const String metadataUrl = 'https://TODO-inserisci-url-current-php-reale';

  // Logo di fallback quando iTunes/Deezer non trovano una cover
  static const String logoAssetPath = 'assets/images/logo.png';

  // Identificativi app (devono combaciare con quanto creato su Play Console / App Store Connect)
  static const String androidApplicationId = 'it.photopix.saurosoftradio';
  static const String iosBundleId = 'it.photopix.saurosoftradio';

  // Intervallo di polling dei metadati (secondi) - stesso valore usato in Android
  static const int metadataPollIntervalSeconds = 12;

  // Testo mostrato nella sezione "Info" dell'app
  static const String infoText =
      'Realizzato da Photopix - Via Filzi 7, Nomi di Trento (TN) - www.photopix.it';

  // Coordinate stazione (usate anche per Amazon Radio Skills Kit)
  static const double stationLat = 45.933;
  static const double stationLon = 11.067;
  static const String stationGenre = 'top';
}
