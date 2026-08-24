import AVKit
import SwiftUI

/// Streams a clip with AVPlayer. The desktop API requires a bearer token, and
/// AVPlayer cannot attach headers to plain URLs — so the token is injected via
/// AVURLAsset's HTTP-header options (public SDK key).
struct PlayerView: View {
    let clip: Clip
    let makeClient: () -> APIClient?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView("Connecting…")
                }
            }
            .navigationTitle(clip.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: startPlayback)
            .onDisappear { player?.pause() }
        }
    }

    private func startPlayback() {
        guard let client = makeClient(), let token = client.token,
              let request = try? client.downloadRequest(for: clip), let url = request.url else {
            return
        }

        // Ranges are supported server-side, so AVPlayer seeks/scrubs efficiently.
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"],
        ])

        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        newPlayer.play()
    }
}
