import Foundation
import Security

/// The only messages crossing the private, embedded XPC connection.
@objc protocol ISTUFetchProtocol {
    func fetch(_ path: String, reply: @escaping (Data?, String?) -> Void)
}

enum ISTUFetchPolicy {
    static let serviceIdentifier = "ru.local.GoldenGateCalendar.ScheduleFetcher"
    static let appIdentifier = "ru.local.GoldenGateCalendar"
    static let serviceBundleName = "ScheduleFetcher.xpc"
    static let maximumBytes = 4 * 1024 * 1024

    /// A path is accepted, never an arbitrary URL, query, redirect, or external resource.
    static func url(for path: String) throws -> URL {
        guard path.utf8.count <= 128 else { throw ISTUFetchError.invalidPath }
        let ordinary = path.range(of: #"\A/raspisanie(?:/(?:podrazdelenie|grup)/[0-9]+)?\z"#, options: .regularExpression) != nil
        let datedPattern = #"\A/raspisanie/grup/[0-9]+/([0-9]{2})\.([0-9]{2})\.([0-9]{4})/\z"#
        var dated = false
        if let expression = try? NSRegularExpression(pattern: datedPattern),
           let match = expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           let dayRange = Range(match.range(at: 1), in: path),
           let monthRange = Range(match.range(at: 2), in: path),
           let yearRange = Range(match.range(at: 3), in: path),
           let day = Int(path[dayRange]), let month = Int(path[monthRange]), let year = Int(path[yearRange]),
           (1...9999).contains(year) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            if let date = calendar.date(from: DateComponents(era: 1, year: year, month: month, day: day)),
               calendar.component(.year, from: date) == year,
               calendar.component(.month, from: date) == month,
               calendar.component(.day, from: date) == day { dated = true }
        }
        guard ordinary || dated,
              let url = URL(string: "https://www.istu.edu" + path),
              url.scheme == "https", url.host == "www.istu.edu", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == path else { throw ISTUFetchError.invalidPath }
        return url
    }

    static func validateResponseURL(_ url: URL) -> Bool {
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let expected = try? self.url(for: path) else { return false }
        return url.absoluteString == expected.absoluteString
    }
}

enum ISTUFetchError: LocalizedError {
    case invalidPath, unavailable, timeout, cancelled, invalidResponse, tooLarge, invalidSignature
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath: "Разрешены только страницы расписания ИРНИТУ без параметров и перенаправлений."
        case .unavailable: "Служба загрузки расписания недоступна."
        case .timeout: "Время ожидания страницы расписания истекло."
        case .cancelled: "Загрузка расписания отменена."
        case .invalidResponse: "Сайт вернул неподходящий ответ вместо HTML-страницы расписания."
        case .tooLarge: "Страница расписания превышает допустимый размер 4 МБ."
        case .invalidSignature: "Не удалось проверить подпись службы загрузки и основного приложения."
        case let .server(message): message
        }
    }
}

/// The host pins its shipped helper's designated requirement. The helper pins
/// the host identifier and signing Team without reading outside its sandbox.
/// NSXPCConnection checks requirements against message audit identity itself.
struct ISTUXPCIdentity: Sendable {
    let requirement: String
    let teamIdentifier: String?

    static func read(bundleURL: URL, expectedIdentifier: String) throws -> Self {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw ISTUFetchError.invalidSignature
        }
        return try identity(for: code, expectedIdentifier: expectedIdentifier)
    }

    private static func identity(for code: SecStaticCode, expectedIdentifier: String) throws -> Self {
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let info = signingInfo as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == expectedIdentifier else {
            throw ISTUFetchError.invalidSignature
        }
        var designated: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &designated) == errSecSuccess,
              let designated,
              SecRequirementCopyString(designated, SecCSFlags(), &text) == errSecSuccess,
              let text else { throw ISTUFetchError.invalidSignature }
        return Self(requirement: text as String, teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    func requireSameTeam(as other: Self) throws {
        guard teamIdentifier == other.teamIdentifier else { throw ISTUFetchError.invalidSignature }
    }

    /// Enforced against the peer's audit identity by NSXPCConnection itself.
    /// An XPC sandbox cannot inspect enclosing app files or other live processes.
    /// Real Team builds require Apple's signing chain and our own Team; the local
    /// ad-hoc build uses the private application-scoped service plus same UID
    /// and expected code identifier, while the host still pins our exact cdhash.
    func hostRequirement() throws -> String {
        var result = "identifier \"\(ISTUFetchPolicy.appIdentifier)\""
        if let teamIdentifier {
            guard teamIdentifier.range(of: #"\A[A-Z0-9]{10}\z"#, options: .regularExpression) != nil else { throw ISTUFetchError.invalidSignature }
            result += " and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(result as CFString, SecCSFlags(), &requirement) == errSecSuccess else { throw ISTUFetchError.invalidSignature }
        return result
    }
}
