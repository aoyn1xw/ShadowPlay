import AVFoundation
import CoreMedia
import Flutter
import Network
import UIKit

private enum HighFrameRateVideoExportError: LocalizedError {
  case sourceMissing
  case noVideoTrack
  case exportSessionUnavailable
  case unsupportedOutputType
  case unsupportedSystemVersion

  var errorDescription: String? {
    switch self {
    case .sourceMissing:
      return "The downloaded video file no longer exists."
    case .noVideoTrack:
      return "The downloaded file does not contain a video track."
    case .exportSessionUnavailable:
      return "iOS could not create a passthrough video export."
    case .unsupportedOutputType:
      return "iOS cannot write this video container without re-encoding."
    case .unsupportedSystemVersion:
      return "Full-frame-rate Photos export requires iOS 18 or newer."
    }
  }
}

private final class HighFrameRateVideoExporter {
  private static let threshold: Float = 120

  func prepare(
    sourcePath: String,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    Task { [self] in
      do {
        let path = try await prepare(sourcePath: sourcePath)
        DispatchQueue.main.async {
          completion(.success(path))
        }
      } catch {
        DispatchQueue.main.async {
          completion(.failure(error))
        }
      }
    }
  }

  private func prepare(sourcePath: String) async throws -> String {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw HighFrameRateVideoExportError.sourceMissing
    }

    let asset = AVURLAsset(url: sourceURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let videoTrack = tracks.first else {
      throw HighFrameRateVideoExportError.noVideoTrack
    }

    let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
    let minimumFrameDuration = try await videoTrack.load(.minFrameDuration)
    let minimumFrameRate: Float
    if minimumFrameDuration.isNumeric && minimumFrameDuration.seconds > 0 {
      minimumFrameRate = Float(1 / minimumFrameDuration.seconds)
    } else {
      minimumFrameRate = 0
    }

    guard max(nominalFrameRate, minimumFrameRate) >= Self.threshold else {
      return sourceURL.path
    }

    guard #available(iOS 18.0, *) else {
      throw HighFrameRateVideoExportError.unsupportedSystemVersion
    }

    guard let exportSession = AVAssetExportSession(
      asset: asset,
      presetName: AVAssetExportPresetPassthrough
    ) else {
      throw HighFrameRateVideoExportError.exportSessionUnavailable
    }

    let outputType = [AVFileType.mp4, AVFileType.mov].first {
      exportSession.supportedFileTypes.contains($0)
    }
    guard let outputType else {
      throw HighFrameRateVideoExportError.unsupportedOutputType
    }

    let extensionName = outputType == .mov ? "mov" : "mp4"
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "ShadowPlay-\(UUID().uuidString).\(extensionName)"
      )

    let intentIdentifier =
      AVMetadataIdentifier.quickTimeMetadataFullFrameRatePlaybackIntent
    var metadata = try await asset.load(.metadata).filter {
      $0.identifier != intentIdentifier
    }

    let intent = AVMutableMetadataItem()
    intent.identifier = intentIdentifier
    intent.keySpace = .quickTimeMetadata
    intent.value = NSNumber(value: UInt8(1))
    intent.dataType = kCMMetadataBaseDataType_UInt8 as String
    metadata.append(intent)
    exportSession.metadata = metadata

    do {
      try await exportSession.export(to: outputURL, as: outputType)
      return outputURL.path
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
  }
}

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
  private let highFrameRateVideoExporter = HighFrameRateVideoExporter()

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
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
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

    let mediaChannel = FlutterMethodChannel(
      name: "shadowplay/media",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    mediaChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "UNAVAILABLE",
            message: "The media exporter is unavailable.",
            details: nil
          )
        )
        return
      }
      guard call.method == "prepareFullFrameRateVideo" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String
      else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENT",
            message: "A video path is required.",
            details: nil
          )
        )
        return
      }

      self.highFrameRateVideoExporter.prepare(sourcePath: path) {
        exportResult in
        switch exportResult {
        case .success(let preparedPath):
          result(preparedPath)
        case .failure(let error):
          result(
            FlutterError(
              code: "HFR_EXPORT_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }
}
