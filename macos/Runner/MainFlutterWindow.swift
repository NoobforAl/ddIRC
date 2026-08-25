import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // Required by window_manager, and copied from its own example. The app hides
  // the native caption and draws its own title bar, which it does from `main`
  // via waitUntilReadyToShow — and that only ever fires if the window starts
  // hidden. Without this the window either shows the system caption for a
  // frame or never shows at all.
  //
  // If the compiler cannot find this, add `import window_manager` above; the
  // upstream example gets away without it and this has not been built yet.
  override public func order(
    _ place: NSWindow.OrderingMode, relativeTo otherWin: Int
  ) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
