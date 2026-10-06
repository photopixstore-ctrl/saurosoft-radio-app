import CarPlay
import Flutter
import UIKit

/// Ponte nativo <-> Dart. Nativo -> Dart: la scena CarPlay chiede al player
/// Flutter di avviare l'ascolto (RadioAudioHandler registra il canale lato
/// Dart). Dart -> nativo: il player comunica il livello del buffer (tacche)
/// da mostrare nel tasto della schermata "In riproduzione".
final class CarPlayBridge {
  static let shared = CarPlayBridge()
  static let channelName = "it.photopix.saurosoft/carplay"

  var channel: FlutterMethodChannel? {
    didSet { attachHandler() }
  }

  /// Ultime tacche ricevute (-1 = non si sta ascoltando).
  private(set) var bufferBars: Int = -1
  var onBufferChanged: ((Int) -> Void)?

  private func attachHandler() {
    channel?.setMethodCallHandler { [weak self] call, result in
      if call.method == "buffer" {
        let bars = (call.arguments as? Int) ?? -1
        DispatchQueue.main.async {
          self?.bufferBars = bars
          self?.onBufferChanged?(bars)
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func invoke(_ method: String, attempt: Int = 0) {
    guard let channel = channel else { return }
    channel.invokeMethod(method, arguments: nil) { result in
      let notReady =
        (result is FlutterError)
        || ((result as? NSObject)?.isEqual(FlutterMethodNotImplemented) == true)
      // All'avvio a freddo da CarPlay Dart puo' non aver ancora registrato il canale.
      if notReady && attempt < 8 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          CarPlayBridge.shared.invoke(method, attempt: attempt + 1)
        }
      }
    }
  }
}

/// Icona a 5 tacche (stile "campo telefono") per il livello del buffer, con la
/// scritta "buffer" piccola sotto.
enum BufferBarsImage {
  static func make(bars: Int) -> UIImage {
    let size = CGSize(width: 44, height: 44)
    let image = UIGraphicsImageRenderer(size: size).image { _ in
      for i in 0..<5 {
        let height = CGFloat(8 + i * 4)
        let rect = CGRect(x: CGFloat(6 + i * 7), y: 28 - height, width: 4, height: height)
        // Immagine "template": il sistema la colora, conta solo l'alpha.
        UIColor.white.withAlphaComponent(i < bars ? 1.0 : 0.3).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 2).fill()
      }
      let label = "buffer" as NSString
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 10, weight: .medium),
        .foregroundColor: UIColor.white,
      ]
      let textSize = label.size(withAttributes: attributes)
      label.draw(
        at: CGPoint(x: (size.width - textSize.width) / 2, y: 31),
        withAttributes: attributes
      )
    }
    return image.withRenderingMode(.alwaysTemplate)
  }
}

/// Schermata di Saurosoft Radio su CarPlay (app audio): barra con le schede
/// "In diretta", "Playlist" e "Informazioni sviluppatore" piu' la schermata
/// standard "In riproduzione" di Apple. In una app audio Apple consente solo
/// questi modelli: niente grafica libera.
@available(iOS 14.0, *)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate {
  private static let playlistUrl = "https://www.saurosoftradio.it/api/playlist.php"
  private static let maxPlaylistItems = 25

  private var interfaceController: CPInterfaceController?
  private var playlistTemplate: CPListTemplate?

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    let logo = UIImage(named: "CarPlayLogo")

    // Scheda 1: la diretta.
    let live = CPListItem(text: "Saurosoft Radio", detailText: "Ascolta in diretta", image: logo)
    live.handler = { [weak self] _, completion in
      CarPlayBridge.shared.invoke("play")
      self?.interfaceController?.pushTemplate(
        CPNowPlayingTemplate.shared,
        animated: true,
        completion: nil
      )
      completion()
    }
    let liveTemplate = CPListTemplate(
      title: "Saurosoft Radio",
      sections: [CPListSection(items: [live])]
    )
    liveTemplate.tabTitle = "In diretta"
    liveTemplate.tabImage = UIImage(systemName: "dot.radiowaves.left.and.right") ?? logo

    // Scheda 2: ultimi brani trasmessi (stessa API della Playlist del telefono).
    let playlist = CPListTemplate(
      title: "Playlist",
      sections: [CPListSection(items: [CPListItem(text: "Caricamento...", detailText: nil)])]
    )
    playlist.tabTitle = "Playlist"
    playlist.tabImage = UIImage(systemName: "music.note.list") ?? logo
    playlistTemplate = playlist

    // Scheda 3: informazioni (stesso testo del telefono, solo righe di testo).
    let infoLines = [
      "App sviluppata da Photopix",
      "www.photopix.it",
      "via Filzi 7, 38060 Nomi (TN)",
      "tel. 0464.350707",
    ]
    let info = CPListTemplate(
      title: "Informazioni sviluppatore",
      sections: [CPListSection(items: infoLines.map { CPListItem(text: $0, detailText: nil) })]
    )
    info.tabTitle = "Informazioni sviluppatore"
    info.tabImage = UIImage(systemName: "info.circle") ?? logo

    let tabBar = CPTabBarTemplate(templates: [liveTemplate, playlist, info])
    tabBar.delegate = self
    interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

    // Tasto con le tacche del buffer nella schermata "In riproduzione".
    CarPlayBridge.shared.onBufferChanged = { [weak self] bars in
      self?.updateBufferButton(bars)
    }
    updateBufferButton(CarPlayBridge.shared.bufferBars)

    loadPlaylist()

    // Avvio automatico quando il telefono si collega a CarPlay (richiesta di
    // Domenico, 6/10): la connessione CarPlay risveglia l'app anche se era in
    // memoria o sospesa, quindi la radio parte senza toccare lo schermo. Una
    // breve attesa lascia il tempo all'uscita audio di passare all'auto.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self, let controller = self.interfaceController else { return }
      CarPlayBridge.shared.invoke("play")
      controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    CarPlayBridge.shared.onBufferChanged = nil
    self.interfaceController = nil
    self.playlistTemplate = nil
  }

  func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
    if selectedTemplate === playlistTemplate {
      loadPlaylist()
    }
  }

  private func updateBufferButton(_ bars: Int) {
    let button = CPNowPlayingImageButton(image: BufferBarsImage.make(bars: max(bars, 0))) { _ in }
    CPNowPlayingTemplate.shared.updateNowPlayingButtons([button])
  }

  private func loadPlaylist() {
    guard let url = URL(string: CarPlaySceneDelegate.playlistUrl) else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 8
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      var items: [CPListItem] = []
      if let data = data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let songs = json["canzoni"] as? [[String: Any]]
      {
        for song in songs.prefix(CarPlaySceneDelegate.maxPlaylistItems) {
          let ora = (song["ora"] as? String) ?? ""
          let artist = (song["artist"] as? String) ?? ""
          let title = (song["title"] as? String) ?? ""
          var brano = "\(artist) - \(title)"
          while let first = brano.first, first == "-" || first == " " {
            brano.removeFirst()
          }
          items.append(CPListItem(text: brano, detailText: ora))
        }
      }
      DispatchQueue.main.async {
        let shown =
          items.isEmpty
          ? [CPListItem(text: "Impossibile caricare la playlist", detailText: nil)]
          : items
        self?.playlistTemplate?.updateSections([CPListSection(items: shown)])
      }
    }.resume()
  }
}
