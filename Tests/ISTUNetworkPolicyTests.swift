import Foundation

@main
struct ISTUNetworkPolicyTests {
    static func main() throws {
        var assertions = 0
        func expect(_ condition: Bool, _ description: String) throws {
            assertions += 1
            if !condition { throw NSError(domain: "ISTUNetworkPolicyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
        }
        func rejectsSignature(_ description: String, _ operation: () throws -> Void) throws {
            var rejected = false
            do { try operation() }
            catch ISTUFetchError.invalidSignature { rejected = true }
            try expect(rejected, description)
        }
        let valid = [
            "/raspisanie", "/raspisanie/podrazdelenie/2", "/raspisanie/grup/478240",
            "/raspisanie/grup/478240/02.11.2026/", "/raspisanie/grup/1/29.02.2000/",
            "/raspisanie/grup/1/29.02.2024/", "/raspisanie/grup/1/01.01.0001/",
            "/raspisanie/grup/1/31.12.9999/"
        ]
        for path in valid {
            let url = try ISTUFetchPolicy.url(for: path)
            try expect(url.absoluteString == "https://www.istu.edu" + path, "Точный HTTPS URL")
            try expect(ISTUFetchPolicy.validateResponseURL(url), "Разрешенный конечный адрес")
        }
        let invalid = [
            "", "/", "/raspisanie/", " /raspisanie", "/raspisanie ", "/raspisanie\n", "/raspisanie\r\n",
            "https://www.istu.edu/raspisanie", "http://www.istu.edu/raspisanie", "https://evil.example/raspisanie",
            "//evil.example/raspisanie", "/raspisanie?week=2", "/raspisanie#x", "/raspisanie/Sys.php",
            "/raspisanie/podrazdelenie/-1", "/raspisanie/grup/-1", "/raspisanie/grup/", "/raspisanie/grup/a",
            "/raspisanie/grup/١", "/raspisanie/grup/1\\x", "/raspisanie//grup/1",
            "/raspisanie/../private", "/raspisanie/grup/1/../../", "/raspisanie/%67rup/1", "/raspisanie/grup/%31",
            "/raspisanie/grup/1/29.02.2100/", "/raspisanie/grup/1/29.02.2025/", "/raspisanie/grup/1/31.04.2026/",
            "/raspisanie/grup/1/32.01.2026/", "/raspisanie/grup/1/00.01.2026/", "/raspisanie/grup/1/01.00.2026/",
            "/raspisanie/grup/1/01.13.2026/", "/raspisanie/grup/1/01.01.0000/", "/raspisanie/grup/1/01.01.10000/",
            "/raspisanie/grup/1/2.11.2026/", "/raspisanie/grup/1/02.1.2026/", "/raspisanie/grup/1/02.11.2026",
            "/raspisanie/grup/1/02.11.2026/?x=1", "/raspisanie/grup/1/02.11.2026/#x",
            "/raspisanie/grup/" + String(repeating: "1", count: 200)
        ]
        for path in invalid { try expect((try? ISTUFetchPolicy.url(for: path)) == nil, "Запрещенный путь: \(path.debugDescription)") }
        let invalidURLs = [
            "http://www.istu.edu/raspisanie", "https://istu.edu/raspisanie", "https://evil.example/raspisanie",
            "https://www.istu.edu.evil.example/raspisanie", "https://user@www.istu.edu/raspisanie",
            "https://user:password@www.istu.edu/raspisanie", "https://www.istu.edu:443/raspisanie",
            "https://www.istu.edu:444/raspisanie", "https://www.istu.edu/raspisanie?x=1",
            "https://www.istu.edu/raspisanie#x", "https://www.istu.edu/raspisanie/%67rup/1",
            "https://www.istu.edu/raspisanie/Sys.php", "file:///raspisanie"
        ]
        for string in invalidURLs {
            try expect(!ISTUFetchPolicy.validateResponseURL(URL(string: string)!), "Запрещенный адрес ответа: \(string)")
        }

        // These cases build local Security requirements only. They never inspect
        // live processes or connect to an XPC service, network, or real store.
        let adHoc = ISTUXPCIdentity(requirement: "local test identity", teamIdentifier: nil)
        try expect(try adHoc.hostRequirement() == "identifier \"ru.local.GoldenGateCalendar\"",
                   "Ad hoc требует ожидаемый identifier без вымышленного Team")
        for team in ["ABCDE12345", "0123456789", "ABCDEFGHIJ"] {
            let identity = ISTUXPCIdentity(requirement: "local test identity", teamIdentifier: team)
            let expected = "identifier \"ru.local.GoldenGateCalendar\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            try expect(try identity.hostRequirement() == expected,
                       "Team \(team) закрепляет identifier, Apple signing chain и точный Team")
        }
        for team in ["", "ABCDE1234", "ABCDE123456", "abcde12345", " ABCDE12345", "ABCDE12345 ",
                     "ABCDE12345\n", "АBCDE12345", "ABCDE-2345", "\" or true"] {
            let identity = ISTUXPCIdentity(requirement: "local test identity", teamIdentifier: team)
            try rejectsSignature("Некорректный Team не попадает в выражение: \(team.debugDescription)") {
                _ = try identity.hostRequirement()
            }
        }

        let signed = ISTUXPCIdentity(requirement: "one exact cdhash", teamIdentifier: "ABCDE12345")
        let sameTeam = ISTUXPCIdentity(requirement: "another exact cdhash", teamIdentifier: "ABCDE12345")
        let differentTeam = ISTUXPCIdentity(requirement: "another identity", teamIdentifier: "ZYXWV98765")
        try signed.requireSameTeam(as: sameTeam)
        try expect(true, "Одинаковый Team разрешен при различных designated requirements")
        try adHoc.requireSameTeam(as: adHoc)
        try expect(true, "Две ad hoc подписи разрешены локальному fallback")
        try rejectsSignature("Другой Team отклоняется") { try signed.requireSameTeam(as: differentTeam) }
        try rejectsSignature("Подписанный host не принимает ad hoc helper") { try signed.requireSameTeam(as: adHoc) }
        try rejectsSignature("Ad hoc host не принимает helper с Team") { try adHoc.requireSameTeam(as: signed) }
        print("ISTUNetworkPolicyTests: \(assertions) проверок пройдено; сетевых запросов не было.")
    }
}
