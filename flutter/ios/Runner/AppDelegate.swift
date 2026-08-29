import Flutter
import Network
import UIKit

private final class LocalNetworkPermissionBridge {
  private var browser: NWBrowser?
  private var completion: ((String) -> Void)?
  private var decisionWorkItem: DispatchWorkItem?
  private var timeoutWorkItem: DispatchWorkItem?

  func requestAccess(completion: @escaping (String) -> Void) {
    stop()
    self.completion = completion

    let browser = NWBrowser(
      for: .bonjour(type: "_http._tcp", domain: "local."),
      using: NWParameters.tcp
    )
    self.browser = browser
    browser.stateUpdateHandler = { [weak self] state in
      self?.handle(state)
    }
    browser.start(queue: .main)

    let timeout = DispatchWorkItem { [weak self] in
      self?.finish("unavailable")
    }
    timeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
  }

  func stop() {
    decisionWorkItem?.cancel()
    timeoutWorkItem?.cancel()
    decisionWorkItem = nil
    timeoutWorkItem = nil
    browser?.cancel()
    browser = nil
    completion = nil
  }

  private func handle(_ state: NWBrowser.State) {
    switch state {
    case .ready:
      // iOS can report ready before the user has answered the alert. Give a
      // subsequent policy-denied transition time to win before granting.
      schedule("granted", after: 1.2)
    case .waiting(let error):
      if isPolicyDenied(error) {
        // The initial waiting/policy-denied state can occur while the alert is
        // still visible. Do not show Settings until that decision settles.
        schedule("denied", after: 2.0)
      }
    case .failed(let error):
      if isPolicyDenied(error) {
        schedule("denied", after: 2.0)
      } else {
        schedule("unavailable", after: 0.2)
      }
    case .cancelled:
      finish("unavailable")
    case .setup:
      break
    @unknown default:
      finish("unavailable")
    }
  }

  private func schedule(_ value: String, after delay: TimeInterval) {
    decisionWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.finish(value)
    }
    decisionWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func isPolicyDenied(_ error: NWError) -> Bool {
    guard case .dns(let code) = error else { return false }
    return Int(code) == -65570 // kDNSServiceErr_PolicyDenied
  }

  private func finish(_ value: String) {
    guard let completion else { return }
    stop()
    completion(value)
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let localNetworkBridge = LocalNetworkPermissionBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "shadowplay/local_network",
      binaryMessenger: engineBridge.applicationRegistrar.messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result("unavailable")
        return
      }
      switch call.method {
      case "requestAccess":
        self.localNetworkBridge.requestAccess { value in
          result(value)
        }
      case "openSettings":
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
          result(opened)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
