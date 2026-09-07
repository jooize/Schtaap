import Foundation

/// Event categories the engine pushes over its websocket.
enum NotifyEvent: String, Sendable, Decodable, CaseIterable {
    case update, database, outputs, player, options, volume, queue
    /// A speaker's own play/pause control was used. The engine does not act
    /// on it (our patch: a pause would close the pipe under librespot), it
    /// only tells us, and the app decides what a speaker's pause means.
    case remotePause = "remote_pause"
    case remotePlay = "remote_play"
}

enum NotifyMessage: Sendable, Equatable {
    case connected
    case events(Set<NotifyEvent>)
    case disconnected(String)
}

/// Subscribes to the engine's push notifications so the UI never polls.
///
/// The engine requires the `notify` websocket subprotocol and an opening
/// message naming the event types we care about. Reconnects with capped
/// exponential backoff, which doubles as the "is the engine up yet?" probe
/// during first launch and after an engine restart.
final class NotifyClient: Sendable {
    private let endpoint: EngineEndpoint
    private let subscriptions: Set<NotifyEvent>

    init(
        endpoint: EngineEndpoint = .default,
        subscriptions: Set<NotifyEvent> = [.outputs, .player, .volume, .queue, .remotePause, .remotePlay]
    ) {
        self.endpoint = endpoint
        self.subscriptions = subscriptions
    }

    /// A stream that lives until the consuming task is cancelled.
    func stream() -> AsyncStream<NotifyMessage> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task { await run(yielding: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(yielding continuation: AsyncStream<NotifyMessage>.Continuation) async {
        var backoff = Duration.seconds(1)

        while !Task.isCancelled {
            do {
                try await connectAndReceive(yielding: continuation)
                backoff = .seconds(1)
            } catch {
                guard !Task.isCancelled else { break }
                continuation.yield(.disconnected(error.localizedDescription))
            }

            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }

        continuation.finish()
    }

    private func connectAndReceive(
        yielding continuation: AsyncStream<NotifyMessage>.Continuation
    ) async throws {
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: endpoint.notifyURL, protocols: ["notify"])
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let payload = ["notify": subscriptions.map(\.rawValue).sorted()]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))

        continuation.yield(.connected)

        while !Task.isCancelled {
            let message = try await socket.receive()
            if let events = Self.events(in: message), !events.isEmpty {
                continuation.yield(.events(events))
            }
        }
    }

    private static func events(in message: URLSessionWebSocketTask.Message) -> Set<NotifyEvent>? {
        let data: Data? = switch message {
        case .string(let text): text.data(using: .utf8)
        case .data(let data): data
        @unknown default: nil
        }
        guard
            let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let names = object["notify"] as? [String]
        else { return nil }

        return Set(names.compactMap(NotifyEvent.init(rawValue:)))
    }
}
