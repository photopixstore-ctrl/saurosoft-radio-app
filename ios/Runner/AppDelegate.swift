import Flutter
import UIKit
import WidgetKit

/// Il motore Flutter (e quindi Dart, AudioService e il player) nasce qui,
/// all'avvio dell'app, e viene condiviso dalla schermata del telefono
/// (SceneDelegate) e dalla scena CarPlay (CarPlaySceneDelegate). Con il
/// motore legato alla sola schermata del telefono, un avvio da CarPlay a
/// telefono bloccato non avrebbe nessun player attivo.
@main
@objc class AppDelegate: FlutterAppDelegate {
  let flutterEngine = FlutterEngine(
    name: "saurosoft_main",
    project: nil,
    allowHeadlessExecution: true
  )

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)

    if let registrar = flutterEngine.registrar(forPlugin: "AirplayButtonPlugin") {
      registrar.register(AirplayButtonFactory(), withId: "saurosoft_airplay_button")
    }

    CarPlayBridge.shared.channel = FlutterMethodChannel(
      name: CarPlayBridge.channelName,
      binaryMessenger: flutterEngine.binaryMessenger
    )

    WidgetBridge.shared.attach(messenger: flutterEngine.binaryMessenger)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Widget "In onda" (estensione RadioWidgetsExtension, vedi ios_widget/). Dart comunica
/// titolo, artista e indirizzo della copertina del brano che si sta ascoltando; qui si
/// scarica la copertina (ridotta a ~300 px), si scrive tutto nell'App Group e si chiede a
/// iOS di ricaricare il widget. Titolo e copertina si scrivono insieme, a copertina pronta,
/// cosi' il widget non mostra mai un titolo nuovo con la copertina vecchia.
final class WidgetBridge {
  static let shared = WidgetBridge()
  static let channelName = "it.photopix.saurosoft/widget"
  static let groupId = "group.it.photopix.saurosoft-radio"
  static let kind = "RadioNowPlayingWidget"
  static let coverFile = "cover.jpg"

  private var channel: FlutterMethodChannel?
  private let queue = DispatchQueue(label: "it.photopix.saurosoft.widget")
  private var generation = 0
  private var lastCoverUrl = ""
  private var hasCover = false

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: WidgetBridge.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "update", let args = call.arguments as? [String: Any] {
        self?.update(
          title: (args["title"] as? String) ?? "",
          artist: (args["artist"] as? String) ?? "",
          cover: (args["cover"] as? String) ?? ""
        )
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  private func update(title: String, artist: String, cover: String) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.generation += 1
      let gen = self.generation
      if cover.isEmpty || cover == self.lastCoverUrl {
        self.commit(title: title, artist: artist)
        return
      }
      self.downloadCover(cover) { [weak self] data in
        self?.queue.async {
          guard let self = self, gen == self.generation else { return }  // superato da un aggiornamento piu' recente
          self.storeCover(data, url: cover)
          self.commit(title: title, artist: artist)
        }
      }
    }
  }

  private func containerUrl() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetBridge.groupId)
  }

  private func downloadCover(_ urlString: String, completion: @escaping (Data?) -> Void) {
    guard let url = URL(string: urlString) else {
      completion(nil)
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 8
    URLSession.shared.dataTask(with: request) { data, response, _ in
      let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
      completion(ok ? data : nil)
    }.resume()
  }

  /// Riduce a ~300 px e salva come JPEG nell'App Group. Senza dati validi toglie la copertina
  /// (il widget mostra l'icona della radio).
  private func storeCover(_ data: Data?, url: String) {
    guard let dir = containerUrl() else { return }
    let file = dir.appendingPathComponent(WidgetBridge.coverFile)
    if let data = data, let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
      let maxSide: CGFloat = 300
      let scale = min(1, maxSide / max(image.size.width, image.size.height))
      let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      let format = UIGraphicsImageRendererFormat.default()
      format.scale = 1
      let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      if let jpeg = small.jpegData(compressionQuality: 0.85), (try? jpeg.write(to: file, options: .atomic)) != nil {
        lastCoverUrl = url
        hasCover = true
        return
      }
    }
    try? FileManager.default.removeItem(at: file)
    lastCoverUrl = ""
    hasCover = false
  }

  private func commit(title: String, artist: String) {
    guard let defaults = UserDefaults(suiteName: WidgetBridge.groupId) else { return }
    defaults.set(title, forKey: "title")
    defaults.set(artist, forKey: "artist")
    defaults.set(hasCover, forKey: "hasCover")
    defaults.set(Date().timeIntervalSince1970, forKey: "updatedAt")
    // L'app e' compilata per iOS 13; WidgetKit esiste da iOS 14 (il widget richiede iOS 17).
    if #available(iOS 14.0, *) {
      WidgetCenter.shared.reloadTimelines(ofKind: WidgetBridge.kind)
    }
  }
}
