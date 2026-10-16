import Foundation

/// Created only by a user-initiated refresh. No connection survives the operation.
@MainActor
final class ISTUFetchClient {
    static func fetch(path: String) async throws -> Data {
        _ = try ISTUFetchPolicy.url(for: path)
        try Task.checkCancellation()
        let appURL = Bundle.main.bundleURL
        let serviceURL = appURL.appendingPathComponent("Contents/XPCServices", isDirectory: true)
            .appendingPathComponent(ISTUFetchPolicy.serviceBundleName, isDirectory: true)
        let appIdentity = try ISTUXPCIdentity.read(bundleURL: appURL, expectedIdentifier: ISTUFetchPolicy.appIdentifier)
        let serviceIdentity = try ISTUXPCIdentity.read(bundleURL: serviceURL, expectedIdentifier: ISTUFetchPolicy.serviceIdentifier)
        try appIdentity.requireSameTeam(as: serviceIdentity)
        let request = ISTUFetchRequest(path: path, serviceRequirement: serviceIdentity.requirement)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in request.start(continuation) }
        } onCancel: {
            request.cancel()
        }
    }
}

private final class ISTUFetchRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let path: String
    private let serviceRequirement: String
    private var continuation: CheckedContinuation<Data, any Error>?
    private var connection: NSXPCConnection?
    private var timeoutWork: DispatchWorkItem?
    private var completed = false
    private var cancellationBeforeStart = false

    init(path: String, serviceRequirement: String) {
        self.path = path
        self.serviceRequirement = serviceRequirement
    }

    func start(_ continuation: CheckedContinuation<Data, any Error>) {
        lock.lock()
        if cancellationBeforeStart {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let connection = NSXPCConnection(serviceName: ISTUFetchPolicy.serviceIdentifier)
        self.connection = connection
        connection.remoteObjectInterface = NSXPCInterface(with: ISTUFetchProtocol.self)
        connection.setCodeSigningRequirement(serviceRequirement)
        connection.invalidationHandler = { [weak self] in self?.finish(.failure(ISTUFetchError.unavailable)) }
        connection.interruptionHandler = { [weak self] in self?.finish(.failure(ISTUFetchError.unavailable)) }
        let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(ISTUFetchError.timeout)) }
        timeoutWork = timeout
        connection.activate()
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.finish(.failure(ISTUFetchError.unavailable))
        }) as? ISTUFetchProtocol else {
            finish(.failure(ISTUFetchError.unavailable))
            return
        }
        proxy.fetch(path) { [weak self] data, error in
            if let error { self?.finish(.failure(ISTUFetchError.server(error))) }
            else if let data, !data.isEmpty, data.count <= ISTUFetchPolicy.maximumBytes { self?.finish(.success(data)) }
            else { self?.finish(.failure(ISTUFetchError.invalidResponse)) }
        }
    }

    func cancel() {
        lock.lock()
        if continuation == nil { cancellationBeforeStart = true }
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !completed, let continuation else { lock.unlock(); return }
        completed = true
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        let timeout = timeoutWork
        timeoutWork = nil
        lock.unlock()
        timeout?.cancel()
        connection?.invalidate()
        continuation.resume(with: result)
    }
}
