import AVKit
import Combine
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var downloads: DownloadManager

    @State private var clips: [Clip] = []
    @State private var errorText: String?
    @State private var playingClip: Clip?
    @State private var showSwitcher = false

    private let pollTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if let connection = state.active {
                    list(connection)
                } else {
                    PairingView()
                }
            }
            .navigationTitle(state.active?.computerName ?? "ShadowPlay")
            .toolbar { toolbarContent }
            .sheet(item: $playingClip) { clip in
                PlayerView(clip: clip, makeClient: { state.makeClient() })
            }
            .alert("Connection problem", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    // MARK: - List

    private func list(_ connection: Connection) -> some View {
        List {
            if let errorText {
                Label(errorText, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }

            ForEach(clips) { clip in
                ClipRow(
                    clip: clip,
                    progress: downloads.progress(for: clip),
                    finished: downloads.isFinished(clip),
                    onPlay: { playingClip = clip },
                    onDownload: { Task { await download(clip) } })
            }

            if clips.isEmpty && errorText == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking for clips…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
        .onReceive(pollTimer) { _ in Task { await refresh(silent: true) } }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Paired PCs") {
                    ForEach(state.connections) { connection in
                        Button {
                            state.setActive(connection)
                            clips = []
                            Task { await refresh() }
                        } label: {
                            Label(connection.computerName,
                                  systemImage: connection.serverId == state.activeServerId ? "checkmark" : "desktopcomputer")
                        }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        if let id = state.activeServerId {
                            state.forget(serverId: id)
                            clips = []
                        }
                    } label: {
                        Label("Forget this PC", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Actions

    private func refresh(silent: Bool = false) async {
        guard let client = state.makeClient() else { return }
        do {
            clips = try await client.clips()
            errorText = nil
        } catch let apiError as APIError {
            if !silent { errorText = apiError.errorDescription }
        } catch {
            if !silent { errorText = error.localizedDescription }
        }
    }

    private func download(_ clip: Clip) async {
        guard let client = state.makeClient() else { return }
        try? await DownloadManager.shared.download(clip, client: client)
    }
}

// MARK: - Row

private struct ClipRow: View {
    let clip: Clip
    let progress: Double?
    let finished: Bool
    let onPlay: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Label(clip.fileName, systemImage: "play.circle.fill")
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteCountFormatter.string(fromByteCount: clip.sizeBytes, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(clip.lastWriteTimeUtc.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            actionButton
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let progress, progress < 1 {
            ProgressView(value: progress)
                .frame(width: 56)
        } else if finished {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}
