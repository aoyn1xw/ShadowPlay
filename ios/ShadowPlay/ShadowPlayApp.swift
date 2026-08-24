import SwiftUI

@main
struct ShadowPlayApp: App {
    @StateObject private var state = AppState()
    @StateObject private var downloads = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(downloads)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.active != nil, state.makeClient() != nil {
            LibraryView()
        } else {
            PairingView()
        }
    }
}
