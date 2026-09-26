import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// The loopback endpoint Claude Code's `PermissionRequest` hook posts to.
///
/// An HTTP hook rather than a command one: Claude Code posts the hook's JSON
/// itself and reads the reply body as the hook's output, so there is no script
/// to ship, install or keep in step with the app. When Codenotch is not
/// running the connection is refused, which Claude Code treats as a hook that
/// said nothing — its own prompt appears in the terminal as if we were never
/// there.
///
/// Each request's connection is held open until the notch answers it. If
/// Claude Code gives up first (the session was interrupted, or answered in the
/// terminal), the connection closes and `onCancel` takes the card down.
// Lifecycle calls come from the main actor; channel state and callbacks are
// confined to the single NIO event loop, as in `OllamaRelayServer`.
final class HookBridgeServer: @unchecked Sendable {
    typealias Reply = @Sendable (PermissionDecision) -> Void

    static let defaultPort = 11436
    static let path = "/claude/permission"

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var listener: Channel?
    private let onRequest: @Sendable (PermissionRequest, @escaping Reply) -> Void
    private let onCancel: @Sendable (UUID) -> Void

    init(onRequest: @escaping @Sendable (PermissionRequest, @escaping Reply) -> Void,
         onCancel: @escaping @Sendable (UUID) -> Void) {
        self.onRequest = onRequest
        self.onCancel = onCancel
    }

    func start(port: Int = HookBridgeServer.defaultPort) async throws -> Int {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false,
                                                             withErrorHandling: true)
                    .flatMap {
                        channel.pipeline.addHandler(HookRequestHandler(onRequest: self.onRequest,
                                                                       onCancel: self.onCancel))
                    }
            }
            .bind(host: "127.0.0.1", port: port).get()
        listener = channel
        return channel.localAddress!.port!
    }

    func stop() async {
        if let listener { try? await listener.close().get() }
        listener = nil
        try? await group.shutdownGracefully()
    }
}

private final class HookRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    private let onRequest: @Sendable (PermissionRequest, @escaping HookBridgeServer.Reply) -> Void
    private let onCancel: @Sendable (UUID) -> Void
    private var head: HTTPRequestHead?
    private var body = Data()
    /// Set once a request is handed to the notch and until it is answered.
    private var pending: UUID?

    init(onRequest: @escaping @Sendable (PermissionRequest, @escaping HookBridgeServer.Reply) -> Void,
         onCancel: @escaping @Sendable (UUID) -> Void) {
        self.onRequest = onRequest
        self.onCancel = onCancel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            // Claude Code sends no Origin; a browser always does. Refusing it
            // keeps a web page from putting cards on the notch.
            guard request.method == .POST, request.uri == HookBridgeServer.path,
                  request.headers["origin"].isEmpty else {
                respond(context.channel, status: .forbidden, body: Data()); return
            }
            head = request
        case .body(let buffer):
            guard body.count + buffer.readableBytes <= 4 * 1024 * 1024 else {
                respond(context.channel, status: .payloadTooLarge, body: Data()); return
            }
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard head != nil else { return }
            guard let request = PermissionRequest.decode(body) else {
                respond(context.channel, status: .ok, body: Data("{}".utf8)); return
            }
            pending = request.id
            let channel = context.channel
            onRequest(request) { [weak self] decision in
                channel.eventLoop.execute {
                    guard let self, self.pending == request.id else { return }
                    self.pending = nil
                    self.respond(channel, status: .ok, body: decision.responseBody(for: request))
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let pending { onCancel(pending) }
        pending = nil
        context.fireChannelInactive()
    }

    private func respond(_ channel: Channel, status: HTTPResponseStatus, body: Data) {
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(
            version: .http1_1, status: status,
            headers: ["content-type": "application/json",
                      "content-length": "\(body.count)", "connection": "close"])), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }
}
