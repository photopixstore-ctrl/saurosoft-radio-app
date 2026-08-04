# Istruzioni per continuare lo sviluppo di Saurosoft Radio su un altro PC

Prompt da incollare a Claude Code (o Claude Desktop con accesso al filesystem) sul PC dove vuoi continuare il lavoro. Il Mac su cui è stato fatto finora era in prestito, quindi si riparte da qui.

---

## Prompt da incollare

```
Sto continuando lo sviluppo di un'app Flutter chiamata "Saurosoft Radio"
(radio streaming, Android + iOS, publisher "Photopix"). Il lavoro finora
è stato fatto su un altro Mac (in prestito) ed è tutto salvato su GitHub.

Repo: https://github.com/photopixstore-ctrl/saurosoft-radio-app.git
Branch principale: main
Ultimo commit noto: 318aacc "Fix build iOS: usa register(_:withId:) invece del vecchio nome"

Setup da fare:
1. Verifica che Flutter sia installato (flutter --version). Se manca,
   installalo (https://flutter.dev) - versione stabile, va bene
   qualsiasi versione recente del canale stable.
2. Clona il repo in una cartella a tua scelta:
   git clone https://github.com/photopixstore-ctrl/saurosoft-radio-app.git
3. Dentro la cartella clonata, esegui: flutter pub get
4. Verifica lo stato con: flutter analyze
   (ci sono 3 errori preesistenti e noti, non bloccanti per l'uso
   dell'app: getter 'logoAssetPath' non definito in
   lib/services/cover_art_service.dart, cartella assets/images/
   mancante, e test/widget_test.dart che referenzia 'MyApp' - da
   sistemare se necessario ma non prioritari)

Contesto tecnico utile:
- Le build iOS (anche solo per il simulatore) si fanno via Codemagic
  (https://codemagic.io/apps, progetto "saurosoft-radio-app"), perché
  serve Xcode completo che potrebbe non essere disponibile in locale.
  Il file codemagic.yaml nella repo ha 3 workflow: build App Store
  (richiede account Apple Developer, non ancora configurato - manca
  APP_STORE_APPLE_ID e l'integrazione App Store Connect), build
  simulatore (nessuna firma richiesta, produce uno zip), build Android
  (Play Store, .aab).
- Per testare le build del simulatore iOS senza un Mac con Xcode: scarica
  lo zip dalla build Codemagic e caricalo su appetize.io (gratuito,
  ~100 minuti/mese), scegli un modello iPhone e premi Play - gira nel
  browser.
- L'ultima feature implementata è il bottone AirPlay nativo iOS
  (ios/Runner/AirplayButtonPlatformView.swift + registrazione in
  AppDelegate.swift), verificato visivamente su Appetize ma non
  ancora testato con dispositivi AirPlay reali (serve iPhone fisico
  + TestFlight + un Apple TV/cassa nelle vicinanze).
- Chromecast su Android NON è implementato - è stato rimosso
  intenzionalmente in una versione precedente (vedi commento in
  lib/widgets/cast_airplay_button.dart), da valutare se reintrodurlo.

Aiutami a proseguire da qui.
```

---

## Nota su git push

Se vuoi pushare modifiche dal nuovo PC, serve che tu abbia accesso in
scrittura al repo GitHub `photopixstore-ctrl/saurosoft-radio-app`
(login GitHub configurato in locale, via HTTPS con token o via SSH).
Se non l'hai ancora configurato su questo PC, dillo a Claude e ti guida.

## Nota su Codemagic

Codemagic è collegato al repo GitHub, non a questo Mac specifico: puoi
lanciare le build da qualsiasi browser con accesso al tuo account
Codemagic, indipendentemente da dove lavori in locale.

## Backup su chiavetta

Una copia completa del repo (con tutta la cronologia git) è salvata
sulla chiavetta, nella cartella `saurosoft_radio_backup_20260804`.
Se non hai connessione internet sul nuovo PC, puoi copiare quella
cartella direttamente invece di clonare da GitHub - contiene già
tutto, remote già puntato a GitHub per quando torni online.
