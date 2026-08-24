import SwiftUI
import UIKit
import VisionKit

/// Pairing: scan the QR shown by the desktop app, or enter details manually
/// (essential for Simulator testing where no camera exists).
struct PairingView: View {
    enum Mode: String, CaseIterable {
        case scan = "Scan QR"
        case manual = "Manual"
    }

    @EnvironmentObject private var state: AppState
    @State private var mode: Mode = .scan

    @State private var payloadText: String?
    @State private var decodeError: String?

    // Manual entry fields
    @State private var address = ""
    @State private var port = "5177"
    @State private var code = ""
    @State private var deviceName = UIDevice.current.name

    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch mode {
                case .scan:
                    scannerSection
                case .manual:
                    manualForm
                }

                if let decodeError {
                    Text(decodeError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Pair with PC")
        }
    }

    // MARK: - QR scanning

    private var scannerSection: some View {
        VStack(spacing: 12) {
            if let payloadText {
                decodedSummary(payloadText)
            } else {
                QRScannerView { scanned in
                    handleScanned(scanned)
                }
                .frame(maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)

                Text("Open ShadowPlay on your PC and scan the pairing code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Enter manually instead") {
                    mode = .manual
                }
                .font(.footnote)
            }

            if let payloadText,
               let payload = try? JSONDecoder().decode(QrPayload.self, from: Data(payloadText.utf8)) {
                if payload.v != QrProtocolVersion.current {
                    Label("This QR uses protocol v\(payload.v). Update both apps.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding()
                } else {
                    pairButton(address: payload.lanAddress, port: String(payload.port), code: payload.pairingCode)
                        .padding()
                }
            }
        }
    }

    private func decodedSummary(_ text: String) -> some View {
        Group {
            if let payload = try? JSONDecoder().decode(QrPayload.self, from: Data(text.utf8)) {
                VStack(spacing: 6) {
                    Label(payload.computerName, systemImage: "desktopcomputer")
                        .font(.title3.bold())
                    Text("\(payload.lanAddress):\(payload.port)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Not a ShadowPlay QR code", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    // MARK: - Manual entry

    private var manualForm: some View {
        VStack(spacing: 0) {
            Form {
                Section("Your PC on this Wi-Fi") {
                    TextField("PC IP address (e.g. 192.168.1.20)", text: $address)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("Pairing code (from the PC window)") {
                    TextField("XXXX-XXXX", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section("Device name shown on the PC") {
                    TextField("Name", text: $deviceName)
                }
            }
            .scrollContentBackground(.hidden)

            pairButton(address: address, port: port, code: code)
                .padding()
        }
    }

    private func pairButton(address: String, port: String, code: String) -> some View {
        Button {
            Task { await pair(address: address, port: port, code: code) }
        } label: {
            HStack {
                if busy { ProgressView().tint(.white) }
                Text(busy ? "Pairing…" : "Pair")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || code.isEmpty)
    }

    // MARK: - Actions

    private func handleScanned(_ text: String) {
        guard payloadText == nil else { return } // debounce repeated scans
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(QrPayload.self, from: data) else {
            decodeError = "Unrecognised QR code"
            return
        }
        decodeError = nil
        payloadText = text
    }

    private func pair(address: String, port: String, code: String) async {
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            errorText = "Port must be a number between 1 and 65535."
            return
        }

        busy = true
        errorText = nil
        defer { busy = false }

        do {
            // The server's identity comes from the exchange response; the QR/manual
            // values only bootstrap the connection.
            let response = try await APIClient.pair(
                address: address.trimmingCharacters(in: .whitespaces),
                port: portNumber,
                code: code.replacingOccurrences(of: " ", with: "-").uppercased(),
                deviceName: deviceName.isEmpty ? "iPhone" : deviceName)

            state.addPaired(
                server: response.server,
                address: address.trimmingCharacters(in: .whitespaces),
                port: portNumber,
                token: response.token)
        } catch {
            errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

enum QrProtocolVersion {
    static let current = 1
}

// MARK: - DataScanner wrapper

struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])]
        )
        controller.delegate = context.coordinator
        do {
            try controller.startScanning()
        } catch {
            // Camera unavailable (e.g. Simulator / permission denied);
            // manual entry mode remains usable.
        }
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var lastPayload: String?

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    guard payload != lastPayload else { continue }
                    lastPayload = payload
                    DispatchQueue.main.async { [onFound] in onFound(payload) }
                }
            }
        }
    }
}
