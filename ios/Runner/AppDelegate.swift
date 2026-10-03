import Flutter
import UIKit

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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
