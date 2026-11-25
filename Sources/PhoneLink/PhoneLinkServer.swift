import Foundation
import Network
import NIOCore
import NIOHTTP1
import NIOPosix

/// Whether phone pairing is offered at all.
///
/// Off until a phone app people can actually install exists: without one the
/// Phone pane and "Connect Phone…" lead nowhere. While off, the server never
/// listens, even for someone who switched it on in a development build.
enum PhoneLink {
    static let isAvailable = false
}

enum PhoneLinkServerState: Equatable {
    case off
    case starting
    case ready(port: Int)
    case failed(String)
}

@MainActor
final class PhoneLinkServerStatus: ObservableObject {
    @Published var state: PhoneLinkServerState = .off
}

enum PhoneLinkServerError: LocalizedError {
    case noPrivateNetwork
    case couldNotListen

    var errorDescription: String? {
        switch self {
        case .noPrivateNetwork: "no private network"
        case .couldNotListen: "Couldn't listen on ports 8788–8798"
        }
    }
}

actor PhoneLinkServer {
    private var group: MultiThreadedEventLoopGroup?
    private var listeners: [String: Channel] = [:]
    private var boundPort: Int?
    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "PhoneLinkServer.NetworkMonitor")
    private var stopped = true

    private let pairing: PhoneLinkPairing
    private let registry: PhoneLinkRegistry
    private let securityStore = SecurityStore()
    private let getSnapshot: @Sendable () async -> Data?
    private let refreshAndGetSnapshot: @Sendable () async -> Data?
    private let hostProvider: @Sendable () -> [String]
    private let status: PhoneLinkServerStatus?

    init(
        pairing: PhoneLinkPairing,
        registry: PhoneLinkRegistry,
        status: PhoneLinkServerStatus? = nil,
        hostProvider: @escaping @Sendable () -> [String] = { PhoneLinkNetwork.getHosts() },
        getSnapshot: @escaping @Sendable () async -> Data?,
        refreshAndGetSnapshot: @escaping @Sendable () async -> Data?
    ) {
        self.pairing = pairing
        self.registry = registry
        self.status = status
        self.hostProvider = hostProvider
        self.getSnapshot = getSnapshot
        self.refreshAndGetSnapshot = refreshAndGetSnapshot
    }

    func start(port: Int = 8788) async throws -> Int {
        if let boundPort, !listeners.isEmpty { return boundPort }

        let privateHosts = currentPrivateHosts()
        guard !privateHosts.isEmpty else {
            await publish(.failed("no private network"))
            throw PhoneLinkServerError.noPrivateNetwork
        }

        stopped = false
        if group == nil {
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        guard let group else { throw PhoneLinkServerError.couldNotListen }

        let candidatePorts = port == 0 ? [0] : [port] + Array(8789...8798).filter { $0 != port }
        var lastError: Error?

        for candidate in candidatePorts {
            let result = await bind(hosts: privateHosts + ["127.0.0.1"], port: candidate, group: group)
            if !result.channels.isEmpty, let actualPort = result.port {
                listeners = result.channels
                boundPort = actualPort
                startNetworkMonitor()
                return actualPort
            }
            lastError = result.lastError
        }

        stopped = true
        throw lastError ?? PhoneLinkServerError.couldNotListen
    }

    func stop() async {
        stopped = true
        monitor?.cancel()
        monitor = nil

        let channels = Array(listeners.values)
        listeners.removeAll()
        boundPort = nil
        for channel in channels {
            try? await channel.close().get()
        }
        if let group {
            try? await group.shutdownGracefully()
            self.group = nil
        }
    }

    private func currentPrivateHosts() -> [String] {
        var seen = Set<String>()
        return hostProvider().filter { PhoneLinkNetwork.isPrivateIPv4($0) && seen.insert($0).inserted }
    }

    private func bind(
        hosts: [String],
        port: Int,
        group: MultiThreadedEventLoopGroup
    ) async -> (channels: [String: Channel], port: Int?, lastError: Error?) {
        var channels: [String: Channel] = [:]
        var selectedPort: Int? = port == 0 ? nil : port
        var lastError: Error?

        for host in hosts {
            do {
                let channel = try await makeBootstrap(group: group)
                    .bind(host: host, port: selectedPort ?? 0).get()
                guard let actualPort = channel.localAddress?.port else {
                    try? await channel.close().get()
                    continue
                }
                selectedPort = actualPort
                channels[host] = channel
            } catch {
                lastError = error
                print("Phone Link couldn't bind \(host):\(selectedPort ?? port): \(error)")
            }
        }
        return (channels, channels.isEmpty ? nil : selectedPort, lastError)
    }

    private func makeBootstrap(group: MultiThreadedEventLoopGroup) -> ServerBootstrap {
        let pairing = self.pairing
        let registry = self.registry
        let securityStore = self.securityStore
        let getSnapshot = self.getSnapshot
        let refreshAndGetSnapshot = self.refreshAndGetSnapshot

        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { @Sendable channel in
                channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false,
                    withErrorHandling: true
                ).flatMap { @Sendable () -> EventLoopFuture<Void> in
                    channel.pipeline.addHandler(PhoneLinkRequestHandler(
                        pairing: pairing,
                        registry: registry,
                        securityStore: securityStore,
                        getSnapshot: getSnapshot,
                        refreshAndGetSnapshot: refreshAndGetSnapshot
                    ))
                }
            }
    }

    private func startNetworkMonitor() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            // Bound here, not inside the `Task`: the handler is a
            // concurrently-executing closure, and Swift 5.10 refuses to read a
            // captured `weak self` var from one nested inside it.
            guard let self else { return }
            Task { await self.networkDidChange() }
        }
        self.monitor = monitor
        monitor.start(queue: monitorQueue)
    }

    private func networkDidChange() async {
        guard !stopped, let port = boundPort, let group else { return }
        let privateHosts = currentPrivateHosts()
        guard !privateHosts.isEmpty else {
            await closeAllListeners()
            await publish(.failed("no private network"))
            return
        }

        let desired = Set(privateHosts + ["127.0.0.1"])
        let removed = listeners.keys.filter { !desired.contains($0) }
        for host in removed {
            if let channel = listeners.removeValue(forKey: host) {
                try? await channel.close().get()
            }
        }

        let added = desired.filter { listeners[$0] == nil }
        if !added.isEmpty {
            let result = await bind(hosts: Array(added).sorted(), port: port, group: group)
            listeners.merge(result.channels) { current, _ in current }
        }

        if listeners.isEmpty {
            await publish(.failed("Couldn't listen on private network"))
        } else {
            await publish(.ready(port: port))
        }
    }

    private func closeAllListeners() async {
        let channels = Array(listeners.values)
        listeners.removeAll()
        for channel in channels {
            try? await channel.close().get()
        }
    }

    private func publish(_ state: PhoneLinkServerState) async {
        guard let status else { return }
        await MainActor.run { status.state = state }
    }
}
