import Foundation

/// The native cloud client has one HTTPS origin, no redirects, cache or analytics.
actor CloudAPI {
    static let origin = "https://simpleschedule-pwa.onrender.com"
    private let session: URLSession
    private let redirectPolicy: CloudRedirectPolicy
    private var cookie: String?
    init(cookie: String? = nil, configuration: URLSessionConfiguration = .ephemeral) {
        self.cookie = cookie
        let policy = CloudRedirectPolicy(); redirectPolicy = policy
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
    }
    func currentCookie() -> String? { cookie }
    func setCookie(_ value: String?) { cookie = value }
    func request<T: Decodable & Sendable>(_ path: String, body: CloudFields? = nil, userID: String? = nil, as type: T.Type = T.self) async throws -> T {
        guard ["/api/auth/session", "/api/auth/request-code", "/api/auth/verify-code", "/api/auth/sign-out", "/api/sync"].contains(path),
              let url = URL(string: Self.origin + path) else { throw CloudError.message("Недопустимый адрес облака.") }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue("1", forHTTPHeaderField: "X-SimpleSchedule")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let userID { request.setValue(userID, forHTTPHeaderField: "X-SimpleSchedule-Account") }
        if let body { request.httpBody = try JSONEncoder().encode(CloudValue.object(body)); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, raw) = try await session.data(for: request)
        guard let response = raw as? HTTPURLResponse, response.url?.host == url.host,
              response.url?.scheme == "https", data.count <= 25_000_000 else { throw CloudError.message("Неподходящий ответ облачного сервера.") }
        if !(200..<300).contains(response.statusCode) {
            let fields = (try? JSONDecoder().decode(CloudValue.self, from: data))?.fields ?? [:]
            throw CloudError.response(response.statusCode, fields["error"]?.string ?? "Облако временно недоступно. Локальные изменения сохранены.",
                response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? fields["retryAfterSeconds"]?.int)
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String { result[key] = String(describing: item.value) }
        }
        if let issued = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).first(where: { $0.name == "SimpleSchedule.Session" || $0.name == "ss_session" }) {
            cookie = "\(issued.name)=\(issued.value)"
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func sync(userID: String, operations: [CloudOperation]) async throws -> CloudReply {
        let value = try JSONDecoder().decode(CloudValue.self, from: JSONEncoder().encode(operations))
        return try await request("/api/sync", body: ["operations": value], userID: userID)
    }
}
private final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
