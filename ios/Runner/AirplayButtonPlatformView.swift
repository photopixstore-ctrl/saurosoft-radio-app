import AVKit
import Flutter
import UIKit

/// Espone AVRoutePickerView (il bottone AirPlay nativo di Apple) come
/// platform view Flutter, per il widget CastAirplayButton
/// (lib/widgets/cast_airplay_button.dart), che lo referenzia con
/// l'id 'saurosoft_airplay_button'.
class AirplayButtonFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return AirplayButtonPlatformView(frame: frame)
  }
}

class AirplayButtonPlatformView: NSObject, FlutterPlatformView {
  private let routePickerView: AVRoutePickerView

  init(frame: CGRect) {
    routePickerView = AVRoutePickerView(frame: frame)
    routePickerView.tintColor = .white
    routePickerView.activeTintColor = .systemBlue
    routePickerView.prioritizesVideoDevices = false
    super.init()
  }

  func view() -> UIView {
    return routePickerView
  }
}
