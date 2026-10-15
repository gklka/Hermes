import Foundation

/// The app's data folder, Application Support/Hermes: the core's databases, media and
/// log, and the app's own caches.
enum AppData {
    nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hermes", isDirectory: true)
}

/// Thin JSON-RPC bridge to the Go core.
///
/// Swift → Go: `MMRequest({"id":…, "method":…, "params":…})`.
/// Go → Swift: a single C callback receiving either
///   `{"type":"response","id":…,"result":…}` / `{"type":"response","id":…,"error":"…"}` or
///   `{"type":"event","event":"…","data":…}`.
final class CoreBridge {
    static let shared = CoreBridge()

    struct CoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated struct Empty: Codable {}

    /// Called on the main thread for every event the core emits.
    var onEvent: ((_ name: String, _ payload: Data) -> Void)?

    private var nextID: Int64 = 0
    private var pending: [Int64: CheckedContinuation<Data, Error>] = [:]
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {}

    func start(dataDirectory: URL) {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        dataDirectory.path.withCString { path in
            MMStart(UnsafeMutablePointer(mutating: path), coreCallback)
        }
    }

    func call<Result: Decodable>(
        _ method: String,
        _ params: some Encodable = Empty(),
        as type: Result.Type
    ) async throws -> Result {
        let data = try await send(method, params)
        return try decoder.decode(ResultBox<Result>.self, from: data).result
    }

    func call(_ method: String, _ params: some Encodable = Empty()) async throws {
        _ = try await send(method, params)
    }

    private func send(_ method: String, _ params: some Encodable) async throws -> Data {
        nextID += 1
        let id = nextID
        let request = try encoder.encode(Request(id: id, method: method, params: params))
        let json = String(decoding: request, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            // Go copies the string synchronously, so the pointer only needs to live for the call.
            json.withCString { MMRequest(UnsafeMutablePointer(mutating: $0)) }
        }
    }

    fileprivate func handle(_ data: Data) {
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            NSLog("CoreBridge: undecodable message from core")
            return
        }
        switch envelope.type {
        case "response":
            guard let id = envelope.id, let continuation = pending.removeValue(forKey: id) else { return }
            if let error = envelope.error {
                continuation.resume(throwing: CoreError(message: error))
            } else {
                continuation.resume(returning: data)
            }
        case "event":
            if let name = envelope.event {
                onEvent?(name, data)
            }
        default:
            break
        }
    }

    /// Writes a line to the core's log file (Application Support/Hermes/core.log).
    func log(_ text: String) {
        struct Params: Encodable { let text: String }
        Task { try? await call("log", Params(text: text)) }
    }

    /// Decodes the `data` field of an event envelope.
    func decodeEvent<T: Decodable>(_ type: T.Type, from payload: Data) -> T? {
        do {
            return try decoder.decode(EventBox<T>.self, from: payload).data
        } catch {
            NSLog("CoreBridge: failed to decode event \(T.self): \(error)")
            return nil
        }
    }

    private struct Request<P: Encodable>: Encodable {
        let id: Int64
        let method: String
        let params: P
    }

    private struct Envelope: Decodable {
        let type: String
        let id: Int64?
        let event: String?
        let error: String?
    }

    private struct ResultBox<R: Decodable>: Decodable {
        let result: R
    }

    private struct EventBox<T: Decodable>: Decodable {
        let data: T
    }
}

/// Invoked by Go on arbitrary threads. The string is only valid during the call, so copy it first.
private nonisolated func coreCallback(_ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let data = Data(bytes: message, count: strlen(message))
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            CoreBridge.shared.handle(data)
        }
    }
}
