import AVFoundation
import CoreMedia
import Flutter
import Network
import OSLog
import UIKit

private enum HighFrameRateVideoExportError: LocalizedError {
  case sourceMissing
  case noVideoTrack
  case exportSessionUnavailable
  case unsupportedOutputType
  case metadataVerificationFailed
  case timingVerificationFailed(String)

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
    case .metadataVerificationFailed:
      return "iOS did not preserve the full-frame-rate metadata in the export."
    case .timingVerificationFailed(let details):
      return "iOS changed the video timing during the export: \(details)"
    }
  }
}

/// Seconds of a CMTime, or nil when the time is invalid or non-numeric.
private func hfrSeconds(_ time: CMTime) -> Double? {
  guard time.isValid, time.isNumeric else { return nil }
  let seconds = time.seconds
  return seconds.isFinite ? seconds : nil
}

/// NaN-safe absolute difference between two optional seconds values; nil when
/// either side is unknown.
private func hfrAbsoluteDelta(_ lhs: Double?, _ rhs: Double?) -> Double? {
  guard let lhs, let rhs else { return nil }
  return abs(lhs - rhs)
}

/// Decimal seconds for logs and reports; "unknown" when the value is missing.
private func hfrDescription(_ seconds: Double?) -> String {
  guard let seconds else { return "unknown" }
  return String(format: "%.6f", seconds)
}

/// Codec fourCC as text: "avc1" for printable codes, hex otherwise.
private func hfrMediaSubTypeName(_ mediaSubType: FourCC?) -> String? {
  guard let mediaSubType else { return nil }
  let bytes = [
    UInt8(truncatingIfNeeded: mediaSubType >> 24),
    UInt8(truncatingIfNeeded: mediaSubType >> 16),
    UInt8(truncatingIfNeeded: mediaSubType >> 8),
    UInt8(truncatingIfNeeded: mediaSubType),
  ]
  guard bytes.allSatisfy({ (32...126).contains($0) }) else {
    return String(format: "0x%08x", mediaSubType)
  }
  return String(bytes: bytes, encoding: .ascii)
}

/// Timing facts reloaded from one of the files involved in an HFR export.
private struct HFRTimingSnapshot {
  let durationSeconds: Double?
  let nominalFrameRate: Float
  let minimumFrameDurationSeconds: Double?
  let mediaSubTypeName: String?
}

#if DEBUG
private final class HFRDiagnosticReport {
  let sourcePath: String
  let sourceSize: Int64
  let sourceDurationSeconds: Double?
  let sourceMediaSubTypeName: String?
  let nominalFrameRate: Float
  let minimumFrameRate: Float
  let detectedFrameRate: Float
  let outputPath: String
  let outputType: String

  var exportStatus = "pending"
  var outputSize: Int64 = 0
  var outputDurationSeconds: Double?
  var outputNominalFrameRate: Float?
  var outputMinimumFrameDurationSeconds: Double?
  var outputMediaSubTypeName: String?
  var metadataFound = false
  var verifiedValue = "not checked"
  var verifiedDataType = "not checked"
  var timingVerdict = "not checked"
  var diagnosticPath = "not created"
  var photosHandoff = "not handed to Photos"
  var photosSave = "not reported"
  var nativeError = "none"

  init(
    sourcePath: String,
    sourceSize: Int64,
    sourceDuration: CMTime,
    sourceMediaSubTypeName: String?,
    nominalFrameRate: Float,
    minimumFrameRate: Float,
    detectedFrameRate: Float,
    outputPath: String,
    outputType: String
  ) {
    self.sourcePath = sourcePath
    self.sourceSize = sourceSize
    self.sourceDurationSeconds = hfrSeconds(sourceDuration)
    self.sourceMediaSubTypeName = sourceMediaSubTypeName
    self.nominalFrameRate = nominalFrameRate
    self.minimumFrameRate = minimumFrameRate
    self.detectedFrameRate = detectedFrameRate
    self.outputPath = outputPath
    self.outputType = outputType
  }

  var text: String {
    """
    ShadowPlay HFR export diagnostic
    source path: \(sourcePath)
    source file name: \(URL(fileURLWithPath: sourcePath).lastPathComponent)
    source file size: \(sourceSize) bytes
    source duration: \(hfrDescription(sourceDurationSeconds)) seconds
    source video codec: \(sourceMediaSubTypeName ?? "unknown")
    detected nominal frame rate: \(nominalFrameRate) fps
    detected minimum frame rate: \(minimumFrameRate) fps
    detected effective frame rate: \(detectedFrameRate) fps
    export preset: \(AVAssetExportPresetPassthrough)
    output file type: \(outputType)
    output path handed to Photos: \(outputPath)
    export status: \(exportStatus)
    output file size: \(outputSize) bytes
    output duration: \(hfrDescription(outputDurationSeconds)) seconds
    output nominal frame rate: \(
      outputNominalFrameRate.map { String(format: "%.3f", $0) } ?? "unknown"
    ) fps
    output minimum frame duration: \(
      hfrDescription(outputMinimumFrameDurationSeconds)
    ) seconds
    output video codec: \(outputMediaSubTypeName ?? "unknown")
    timing verification: \(timingVerdict)
    FullFrameRatePlaybackIntent found after reopening: \(metadataFound)
    verified metadata value: \(verifiedValue)
    verified metadata datatype: \(verifiedDataType)
    diagnostic MP4 path: \(diagnosticPath)
    Photos/gallery handoff: \(photosHandoff)
    Photos/gallery save: \(photosSave)
    native export/verification error: \(nativeError)
    """
  }
}
#endif

private final class HighFrameRateVideoExporter {
  private static let threshold: Float = 120
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ShadowPlay",
    category: "HFRExport"
  )

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

    let sourceSize = (try? FileManager.default.attributesOfItem(
      atPath: sourceURL.path
    )[.size] as? NSNumber)?.int64Value ?? 0
    logger.info(
      "source path=\(sourceURL.path, privacy: .public) size=\(sourceSize)"
    )

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

    let detectedFrameRate = max(nominalFrameRate, minimumFrameRate)
    logger.info(
      "frameRate nominal=\(nominalFrameRate) minimum=\(minimumFrameRate) detected=\(detectedFrameRate) threshold=\(Self.threshold)"
    )

    guard detectedFrameRate >= Self.threshold else {
      logger.info("export status=skipped reason=ordinary-video")
      return sourceURL.path
    }

    let sourceDuration = try await asset.load(.duration)
    let sourceFormatDescriptions = try await videoTrack.load(
      .formatDescriptions
    )
    let sourceMediaSubType = sourceFormatDescriptions.first.map(
      CMFormatDescriptionGetMediaSubType
    )
    logger.info(
      "source duration=\(hfrDescription(hfrSeconds(sourceDuration))) codec=\(hfrMediaSubTypeName(sourceMediaSubType) ?? "unknown", privacy: .public)"
    )

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

    logger.info(
      "export preset=\(AVAssetExportPresetPassthrough, privacy: .public) fileType=\(outputType.rawValue, privacy: .public)"
    )

    let extensionName = outputType == .mov ? "mov" : "mp4"
    let outputFileName = "ShadowPlay-\(UUID().uuidString).\(extensionName)"
#if DEBUG
    let diagnosticsDirectory = diagnosticsDirectoryURL()
    try FileManager.default.createDirectory(
      at: diagnosticsDirectory,
      withIntermediateDirectories: true
    )
    let outputURL = diagnosticsDirectory.appendingPathComponent(outputFileName)
#else
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(outputFileName)
#endif

#if DEBUG
    let diagnosticReport = HFRDiagnosticReport(
      sourcePath: sourceURL.path,
      sourceSize: sourceSize,
      sourceDuration: sourceDuration,
      sourceMediaSubTypeName: hfrMediaSubTypeName(sourceMediaSubType),
      nominalFrameRate: nominalFrameRate,
      minimumFrameRate: minimumFrameRate,
      detectedFrameRate: detectedFrameRate,
      outputPath: outputURL.path,
      outputType: String(describing: outputType)
    )
    writeDiagnosticReport(diagnosticReport)
#endif

    do {
      let intentIdentifier =
        AVMetadataIdentifier.quickTimeMetadataFullFrameRatePlaybackIntent
      let sourceMetadata = try await asset.load(.metadata)
      var metadata = sourceMetadata.filter {
        $0.identifier != intentIdentifier
      }

      let sourceIntentCount = sourceMetadata.filter {
        $0.identifier == intentIdentifier
      }.count
      logger.info("source fullFrameRatePlaybackIntent count=\(sourceIntentCount)")

      let intent = AVMutableMetadataItem()
      intent.identifier = intentIdentifier
      intent.keySpace = .quickTimeMetadata
      intent.value = NSNumber(value: UInt8(1))
      intent.dataType = kCMMetadataBaseDataType_UInt8 as String
      metadata.append(intent)
      exportSession.metadata = metadata

      logger.info(
        "export status=started tempPath=\(outputURL.path, privacy: .public)"
      )
      try await exportSession.export(to: outputURL, as: outputType)

      let outputSize = (try? FileManager.default.attributesOfItem(
        atPath: outputURL.path
      )[.size] as? NSNumber)?.int64Value ?? 0
      logger.info(
        "export status=completed tempPath=\(outputURL.path, privacy: .public) tempSize=\(outputSize)"
      )
#if DEBUG
      diagnosticReport.exportStatus = "success"
      diagnosticReport.outputSize = outputSize
#endif
      try await verifyFullFrameRateIntent(
        at: outputURL,
        identifier: intentIdentifier
      )
#if DEBUG
      let outputTiming = try await verifyTimingPreserved(
        sourceDuration: sourceDuration,
        sourceNominalFrameRate: nominalFrameRate,
        sourceMinimumFrameDuration: minimumFrameDuration,
        sourceMediaSubType: sourceMediaSubType,
        at: outputURL
      )
      diagnosticReport.metadataFound = true
      diagnosticReport.verifiedValue = "1"
      diagnosticReport.verifiedDataType = kCMMetadataBaseDataType_UInt8 as String
      diagnosticReport.timingVerdict = "passed"
      diagnosticReport.outputDurationSeconds = outputTiming.durationSeconds
      diagnosticReport.outputNominalFrameRate = outputTiming.nominalFrameRate
      diagnosticReport.outputMinimumFrameDurationSeconds =
        outputTiming.minimumFrameDurationSeconds
      diagnosticReport.outputMediaSubTypeName = outputTiming.mediaSubTypeName
      diagnosticReport.diagnosticPath = outputURL.path
      logger.info(
        "diagnostic MP4 path=\(outputURL.path, privacy: .public) exactPhotosPath=true"
      )
      writeDiagnosticReport(diagnosticReport)
#else
      try await verifyTimingPreserved(
        sourceDuration: sourceDuration,
        sourceNominalFrameRate: nominalFrameRate,
        sourceMinimumFrameDuration: minimumFrameDuration,
        sourceMediaSubType: sourceMediaSubType,
        at: outputURL
      )
#endif

      return outputURL.path
    } catch {
#if DEBUG
      diagnosticReport.exportStatus = "failure"
      diagnosticReport.nativeError = error.localizedDescription
      if let exportError = error as? HighFrameRateVideoExportError,
        case .timingVerificationFailed = exportError {
        diagnosticReport.timingVerdict = "failed"
      }
      writeDiagnosticReport(diagnosticReport)
#endif
      try? FileManager.default.removeItem(at: outputURL)
      logger.error(
        "export status=failed tempPath=\(outputURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }

  private func verifyFullFrameRateIntent(
    at outputURL: URL,
    identifier: AVMetadataIdentifier
  ) async throws {
    let exportedAsset = AVURLAsset(url: outputURL)
    let exportedMetadata = try await exportedAsset.load(.metadata)
    guard let item = exportedMetadata.first(where: {
      $0.identifier == identifier
    }) else {
      logger.error("metadata verification=failed reason=identifier-missing")
      throw HighFrameRateVideoExportError.metadataVerificationFailed
    }

    let expectedDataType = kCMMetadataBaseDataType_UInt8 as String
    let numberValue = try await item.load(.numberValue)
    guard item.dataType == expectedDataType, numberValue?.intValue == 1 else {
      logger.error(
        "metadata verification=failed reason=value-or-datatype-mismatch dataType=\(item.dataType ?? "nil", privacy: .public) value=\(numberValue?.intValue ?? -1)"
      )
      throw HighFrameRateVideoExportError.metadataVerificationFailed
    }

    logger.info(
      "metadata verification=passed identifier=\(String(describing: identifier), privacy: .public) value=1 dataType=\(expectedDataType, privacy: .public)"
    )
  }

  /// Reopens the exported file and re-measures it with AVFoundation so a
  /// passthrough export is proven to have kept the source's timing and codec.
  private func verifyTimingPreserved(
    sourceDuration: CMTime,
    sourceNominalFrameRate: Float,
    sourceMinimumFrameDuration: CMTime,
    sourceMediaSubType: FourCC?,
    at outputURL: URL
  ) async throws -> HFRTimingSnapshot {
    let exportedAsset = AVURLAsset(url: outputURL)
    let exportedTracks = try await exportedAsset.loadTracks(withMediaType: .video)
    guard let exportedTrack = exportedTracks.first else {
      logger.error("timing verification=failed reason=no-video-track")
      throw HighFrameRateVideoExportError.timingVerificationFailed(
        "the exported file has no video track"
      )
    }
    let exportedDuration = try await exportedAsset.load(.duration)
    let exportedNominalFrameRate = try await exportedTrack.load(.nominalFrameRate)
    let exportedMinimumFrameDuration = try await exportedTrack.load(
      .minFrameDuration
    )
    let formatDescriptions = try await exportedTrack.load(.formatDescriptions)
    let exportedMediaSubType = formatDescriptions.first.map(
      CMFormatDescriptionGetMediaSubType
    )

    let output = HFRTimingSnapshot(
      durationSeconds: hfrSeconds(exportedDuration),
      nominalFrameRate: exportedNominalFrameRate,
      minimumFrameDurationSeconds: hfrSeconds(exportedMinimumFrameDuration),
      mediaSubTypeName: hfrMediaSubTypeName(exportedMediaSubType)
    )

    var mismatches: [String] = []
    // Container timescales (for example 600 or 165000) can shift recorded
    // durations by a small fraction of a frame, so tolerate at most half a
    // source frame or 2 ms, whichever is larger.
    let halfSourceFrameSeconds =
      hfrSeconds(sourceMinimumFrameDuration)
      .map { max(0.002, $0 / 2) } ?? 0.002

    let durationDelta = hfrAbsoluteDelta(
      hfrSeconds(sourceDuration),
      output.durationSeconds
    )
    if let durationDelta, durationDelta > halfSourceFrameSeconds {
      mismatches.append(
        "duration source=\(hfrDescription(hfrSeconds(sourceDuration))) output=\(hfrDescription(output.durationSeconds))"
      )
    }

    let minimumFrameDurationDelta = hfrAbsoluteDelta(
      hfrSeconds(sourceMinimumFrameDuration),
      output.minimumFrameDurationSeconds
    )
    if let minimumFrameDurationDelta,
      minimumFrameDurationDelta > halfSourceFrameSeconds {
      mismatches.append(
        "minimumFrameDuration source=\(hfrDescription(hfrSeconds(sourceMinimumFrameDuration))) output=\(hfrDescription(output.minimumFrameDurationSeconds))"
      )
    }

    // nominalFrameRate is negative when unknown; only compare recorded values.
    if sourceNominalFrameRate > 0,
      abs(Double(sourceNominalFrameRate - output.nominalFrameRate)) > 0.5 {
      mismatches.append(
        "nominalFrameRate source=\(String(format: "%.3f", sourceNominalFrameRate)) output=\(String(format: "%.3f", output.nominalFrameRate))"
      )
    }

    if let sourceMediaSubType, let exportedMediaSubType,
      sourceMediaSubType != exportedMediaSubType {
      // A different codec fourCC means the export re-encoded the video.
      mismatches.append(
        "codec source=\(hfrMediaSubTypeName(sourceMediaSubType) ?? "unknown") output=\(hfrMediaSubTypeName(exportedMediaSubType) ?? "unknown")"
      )
    }

    if !mismatches.isEmpty {
      let details = mismatches.joined(separator: "; ")
      logger.error("timing verification=failed \(details, privacy: .public)")
      throw HighFrameRateVideoExportError.timingVerificationFailed(details)
    }

    logger.info(
      "timing verification=passed duration=\(hfrDescription(output.durationSeconds)) nominal=\(String(format: "%.3f", output.nominalFrameRate)) minimum=\(hfrDescription(output.minimumFrameDurationSeconds)) codec=\(output.mediaSubTypeName ?? "unknown", privacy: .public)"
    )
    return output
  }

  func recordPhotosSaveResult(
    path: String,
    status: String,
    error: String?
  ) {
    logger.info(
      "photos handoff path=\(path, privacy: .public) status=\(status, privacy: .public)"
    )
#if DEBUG
    guard let reportURL = diagnosticReportURL(for: path),
      FileManager.default.fileExists(atPath: reportURL.path)
    else {
      return
    }

    var update = "\nPhotos/gallery handoff path: \(path)\n"
    update += "Photos/gallery handoff status: \(status)\n"
    update += "Photos/gallery save: \(status)\n"
    if let error, !error.isEmpty {
      update += "Photos/gallery error: \(error)\n"
    }
    do {
      let existing = try String(contentsOf: reportURL, encoding: .utf8)
      try (existing + update).write(to: reportURL, atomically: true, encoding: .utf8)
    } catch {
      logger.error(
        "diagnostic report update failed error=\(error.localizedDescription, privacy: .public)"
      )
    }
#endif
  }

#if DEBUG
  private func diagnosticsDirectoryURL() -> URL {
    let documentsURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    )[0]
    return documentsURL.appendingPathComponent(
      "ShadowPlayDiagnostics",
      isDirectory: true
    )
  }

  private func diagnosticReportURL(for outputPath: String) -> URL? {
    diagnosticsDirectoryURL().appendingPathComponent(
      URL(fileURLWithPath: outputPath).lastPathComponent + ".txt"
    )
  }

  private func writeDiagnosticReport(_ report: HFRDiagnosticReport) {
    do {
      let directoryURL = diagnosticsDirectoryURL()
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      guard let reportURL = diagnosticReportURL(for: report.outputPath) else {
        return
      }
      try report.text.write(to: reportURL, atomically: true, encoding: .utf8)
    } catch {
      logger.error(
        "diagnostic report write failed error=\(error.localizedDescription, privacy: .public)"
      )
    }
  }

#endif
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
      switch call.method {
      case "prepareFullFrameRateVideo":
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
      case "recordPhotosSaveResult":
        guard
          let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String,
          let status = arguments["status"] as? String
        else {
          result(
            FlutterError(
              code: "INVALID_ARGUMENT",
              message: "A Photos save path and status are required.",
              details: nil
            )
          )
          return
        }

        self.highFrameRateVideoExporter.recordPhotosSaveResult(
          path: path,
          status: status,
          error: arguments["error"] as? String
        )
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
