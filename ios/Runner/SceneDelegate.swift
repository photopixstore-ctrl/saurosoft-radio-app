import Flutter
import UIKit

/// Scena della schermata del telefono: crea la finestra con una
/// FlutterViewController agganciata al motore condiviso dell'AppDelegate.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let windowScene = scene as? UIWindowScene,
      let appDelegate = UIApplication.shared.delegate as? AppDelegate
    {
      let controller = FlutterViewController(
        engine: appDelegate.flutterEngine,
        nibName: nil,
        bundle: nil
      )
      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = controller
      self.window = window
      window.makeKeyAndVisible()
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
