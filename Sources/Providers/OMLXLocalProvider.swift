import Foundation

/// The provider id and cell-id namespace for oMLX, kept apart from the
/// provider so the metrics type can share them without importing each other.
enum OMLXIdentity {
    static let providerID = "omlx"

    static func cellID(instance: String) -> String { "\(providerID):model:\(instance)" }
}

/// oMLX's loaded models, read from its own status listing on the local
/// server. Nothing is loaded, unloaded or generated from here.
///
/// The key is borrowed from oMLX's settings file and is optional on purpose:
/// when oMLX skips key verification, or no key exists, no header is sent. A 401
/// then means the server wants a key this Mac cannot supply, and Settings says
/// so; it is not a sign-out, because there is no account here to be signed out
/// of.
@MainActor
final class OMLXLocalProvider: UsageProvider {
    nonisolated let id = OMLXIdentity.providerID
    nonisolated let displayName = "oMLX"
    nonisolated let glyph = ProviderGlyph.omlx
    nonisolated let kind = ProviderKind.localRuntime

    nonisolated var isVisibleWhenAbsent: Bool { false }
    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: "app.omlx", name: "oMLX")
    }

    var endpoint: URL {
        didSet { if endpoint != oldValue { cached = nil } }
    }
    private let session: URLSession
    private let key: () -> String?
    private let inventoryInterval: TimeInterval
    private let now: () -> Date
    private var cached: (at: Date, snapshot: ProviderSnapshot)?

    /// `inventoryInterval`: the store asks every local runtime once a second,
    /// and the model inventory changes a few times a day. A listing this old is
    /// answered from memory instead of being requested again.
    init(endpoint: URL = URL(string: OMLXEndpoint.defaultAddress)!, session: URLSession? = nil,
         key: @escaping () -> String? = { OMLXCredentials.load() },
         inventoryInterval: TimeInterval = 5, now: @escaping () -> Date = Date.init) {
        self.endpoint = endpoint
        self.session = session ?? OllamaLocalProvider.makeSession()
        self.key = key
        self.inventoryInterval = inventoryInterval
        self.now = now
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let cached, now().timeIntervalSince(cached.at) < inventoryInterval { return cached.snapshot }
        let snapshot = try await fetchListing()
        cached = (now(), snapshot)
        return snapshot
    }

    private func fetchListing() async throws -> ProviderSnapshot {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/models/status"))
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = key() {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OMLXError.unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw OMLXError.needsKey }
        guard status == 200 else { throw OMLXError.http(status) }
        let reading = try OMLXUsage.parse(data)
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: [],
                                kind: kind, localRuntime: reading)
    }
}
