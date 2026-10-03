import CarPlay
import Flutter
import UIKit

/// Ponte nativo -> Dart: la scena CarPlay chiede al player Flutter di
/// avviare l'ascolto (RadioAudioHandler registra il canale lato Dart).
final class CarPlayBridge {
  static let shared = CarPlayBridge()
  static let channelName = "it.photopix.saurosoft/carplay"

  var channel: FlutterMethodChannel?

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

/// Schermata di Saurosoft Radio su CarPlay (app audio): un elenco con la
/// diretta e la schermata standard "In riproduzione" di Apple.
@available(iOS 14.0, *)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var interfaceController: CPInterfaceController?

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController

    let live = CPListItem(text: "Saurosoft Radio", detailText: "Ascolta in diretta")
    live.handler = { [weak self] _, completion in
      CarPlayBridge.shared.invoke("play")
      self?.interfaceController?.pushTemplate(
        CPNowPlayingTemplate.shared,
        animated: true,
        completion: nil
      )
      completion()
    }

    let list = CPListTemplate(
      title: "Saurosoft Radio",
      sections: [CPListSection(items: [live])]
    )
    interfaceController.setRootTemplate(list, animated: false, completion: nil)
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    self.interfaceController = nil
  }
}
