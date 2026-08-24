import Foundation

/// Streams clip downloads to the app's Documents folder (visible in Files/Finder
/// thanks to UIFileSharingEnabled) with per-clip progress.
///
/// The byte-pumping loop deliberately runs OFF the main actor (static method);
/// only progress bookkeeping touches @MainActor state, once per megabyte.
@MainActor
final class DownloadManager: ObservableObject {
    struct Task: Identifiable {
        let id: String // clip id
        let fileName: String
        var receivedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var finished: Bool = false
        var failed: Bool = false
    }

    @Published private(set) var tasks: [String: Task] = [:]
    @Published private(set) var completedFiles: [String: URL] = [:]

    static let shared = DownloadManager()

    private init() {}

    func progress(for clip: Clip) -> Double? {
        tasks[clip.id].map { task in
            guard !task.finished, task.totalBytes > 0 else { return task.failed ? 0 : 1 }
            return Double(task.receivedBytes) / Double(task.totalBytes)
        }
    }

    func isFinished(_ clip: Clip) -> Bool {
        tasks[clip.id]?.finished == true || completedFiles[clip.id] != nil
    }

    func download(_ clip: Clip, client: APIClient) async throws {
        if completedFiles[clip.id] != nil { return }

        tasks[clip.id] = Task(id: clip.id, fileName: clip.fileName)

        do {
            let request = try client.downloadRequest(for: clip)

            let (received, total) = try await Self.pump(
                request: request,
                destination: Self.destinationURL(for: clip.fileName),
                onChunk: { [weak self] receivedBytes, totalBytes in
                    Task { @MainActor in
                        self?.update(clipId: clip.id, received: receivedBytes, total: totalBytes)
                    }
                })

            if var task = tasks[clip.id] {
                task.receivedBytes = received
                task.totalBytes = total > 0 ? total : received
                task.finished = true
                tasks[clip.id] = task
            }
            completedFiles[clip.id] = Self.destinationURL(for: clip.fileName)
        } catch {
            if var task = tasks[clip.id] {
                task.failed = true
                tasks[clip.id] = task
            }
            throw error
        }
    }

    /// Runs off the main actor: streams response bytes to disk in ~1 MB chunks.
    private static func pump(
        request: URLRequest,
        destination: URL,
        onChunk: @escaping (Int64, Int64) -> Void
    ) async throws -> (received: Int64, totalExpected: Int64) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let total = response.expectedContentLength

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReported: Int64 = -1

        for try await byte in bytes {
            buffer.append(byte)
            received += 1

            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if received != lastReported {
                    lastReported = received
                    onChunk(received, total)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        return (received, total)
    }

    private func update(clipId: String, received: Int64, total: Int64) {
        guard var task = tasks[clipId], !task.finished else { return }
        task.receivedBytes = received
        task.totalBytes = total
        tasks[clipId] = task
    }

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func destinationURL(for fileName: String) -> URL {
        documentsDirectory().appendingPathComponent(fileName)
    }
}
