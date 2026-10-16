import Foundation
import Darwin

/// One GET per connection; no shared storage, cookies, downloaded resources, or background refresh.
private final class HTMLFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var bytes = Data()
    private var completed = false
    private let completion: (Data?, String?) -> Void

    init(completion: @escaping (Data?, String?) -> Void) { self.completion = completion }

    func start(path: String) {
        do {
            let url = try ISTUFetchPolicy.url(for: path)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 1
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            // Keep system proxy and default TLS trust evaluation; never fetch PAC ourselves.
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.setValue("GoldenGateCalendar/1.0 (manual schedule refresh)", forHTTPHeaderField: "User-Agent")
            lock.lock()
            guard !completed else { lock.unlock(); session.invalidateAndCancel(); return }
            self.session = session
            session.dataTask(with: request).resume()
            lock.unlock()
        } catch { finish(data: nil, error: error.localizedDescription) }
    }

    func cancel() { finish(data: nil, error: ISTUFetchError.cancelled.localizedDescription) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(data: nil, error: "Сайт предложил перенаправление. Загрузка остановлена без перехода на другой адрес.")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, ISTUFetchPolicy.validateResponseURL(url),
              ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else {
            completionHandler(.cancel)
            finish(data: nil, error: ISTUFetchError.invalidResponse.localizedDescription)
            return
        }
        guard response.expectedContentLength <= Int64(ISTUFetchPolicy.maximumBytes) else {
            completionHandler(.cancel)
            finish(data: nil, error: ISTUFetchError.tooLarge.localizedDescription)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard data.count <= ISTUFetchPolicy.maximumBytes - bytes.count else {
            lock.unlock()
            finish(data: nil, error: ISTUFetchError.tooLarge.localizedDescription)
            return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(data: nil, error: "Не удалось загрузить страницу расписания: \(error.localizedDescription)") }
        else {
            lock.lock()
            let data = bytes
            lock.unlock()
            finish(data: data.isEmpty ? nil : data, error: data.isEmpty ? ISTUFetchError.invalidResponse.localizedDescription : nil)
        }
    }

    private func finish(data: Data?, error: String?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let session = self.session
        self.session = nil
        bytes.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        completion(data, error)
    }
}

private final class FetchConnection: NSObject, ISTUFetchProtocol, @unchecked Sendable {
    let connection: NSXPCConnection
    private let lock = NSLock()
    private var used = false
    private var operation: HTMLFetch?

    init(connection: NSXPCConnection) { self.connection = connection }

    func fetch(_ path: String, reply: @escaping (Data?, String?) -> Void) {
        lock.lock()
        guard !used else { lock.unlock(); reply(nil, "Каждое соединение допускает только одну загрузку."); return }
        used = true
        let operation = HTMLFetch { [weak self] data, error in
            reply(data, error)
            // Allow the reply to leave the process even if a client does not invalidate itself.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.connection.invalidate() }
        }
        self.operation = operation
        lock.unlock()
        operation.start(path: path)
    }

    func cancel() {
        lock.lock()
        let operation = self.operation
        self.operation = nil
        lock.unlock()
        operation?.cancel()
    }
}

private final class FetchListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: FetchConnection] = [:]
    private var exitGeneration = 0
    private let hostRequirement: String

    init(hostRequirement: String) {
        self.hostRequirement = hostRequirement
        super.init()
        // Bound an instance whose initiating client never completes the handshake.
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let idle = self.clients.isEmpty
            self.lock.unlock()
            if idle { exit(0) }
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.setCodeSigningRequirement(hostRequirement)
        let client = FetchConnection(connection: connection)
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        clients[identifier] = client
        exitGeneration += 1
        lock.unlock()
        connection.exportedInterface = NSXPCInterface(with: ISTUFetchProtocol.self)
        connection.exportedObject = client
        connection.invalidationHandler = { [weak self] in self?.disconnect(identifier) }
        connection.interruptionHandler = { [weak client] in client?.connection.invalidate() }
        connection.activate()
        // A later request may reuse the same XPC process. Bound each connection
        // independently so an old process-wide timer never aborts the next page.
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) { [weak client] in client?.connection.invalidate() }
        return true
    }

    private func disconnect(_ identifier: ObjectIdentifier) {
        lock.lock()
        let client = clients.removeValue(forKey: identifier)
        exitGeneration += 1
        let generation = exitGeneration
        let shouldExit = clients.isEmpty
        lock.unlock()
        client?.cancel()
        if shouldExit {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let exitNow = self.clients.isEmpty && self.exitGeneration == generation
                self.lock.unlock()
                if exitNow { exit(0) }
            }
        }
    }
}

@main
private struct ScheduleFetcherMain {
    static func main() {
        do {
            let serviceURL = Bundle.main.bundleURL
            let service = try ISTUXPCIdentity.read(bundleURL: serviceURL, expectedIdentifier: ISTUFetchPolicy.serviceIdentifier)
            let delegate = FetchListener(hostRequirement: try service.hostRequirement())
            let listener = NSXPCListener.service()
            listener.delegate = delegate
            withExtendedLifetime(delegate) { listener.resume() }
        } catch {
            fputs("Не удалось проверить подпись собственного приложения.\n", stderr)
            exit(78)
        }
    }
}
