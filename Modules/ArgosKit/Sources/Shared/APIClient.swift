import Foundation

struct Connection: Codable, Equatable {
    var baseURL: URL
    var token: String
}

enum APIError: LocalizedError {
    case unauthorized
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Jeton refusé par le serveur."
        case .server(let msg): msg
        case .network(let msg): "Serveur injoignable : \(msg)"
        }
    }
}

struct APIClient {
    let connection: Connection

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Le serveur envoie des dates ISO 8601, avec ou sans fraction de seconde.
        let precise = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? precise.parse(s)) ?? (try? plain.parse(s)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date invalide : \(s)"))
        }
        return d
    }()

    @discardableResult
    /// `json` : corps déjà encodé (appels faits pour une autre app d'Égide).
    func send(_ path: String, method: String = "GET", body: (any Encodable)? = nil, json: Data? = nil) async throws -> Data {
        // appending(path:) encoderait le « ? » d'éventuels paramètres : on les ajoute à part.
        let (route, query) = path.split(separator: "?", maxSplits: 1).map(String.init).splitFirst()
        var url = connection.baseURL.appending(path: route)
        if let query, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.percentEncodedQuery = query
            url = comps.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if let json = try body.map({ try JSONEncoder().encode($0) }) ?? json {
            req.httpBody = json
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError.server(msg?.isEmpty == false ? msg! : "Erreur HTTP \(code)")
        }
        return data
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try Self.decoder.decode(T.self, from: try await send(path))
    }

    func devices() async throws -> [DeviceSummary] { try await get("api/devices") }

    func device(_ id: String) async throws -> DeviceDetail { try await get("api/devices/\(id)") }

    func deleteDevice(_ id: String) async throws { try await send("api/devices/\(id)", method: "DELETE") }

    /// Nouveau scan immédiat d'un ordinateur, ou de tous les ordinateurs en ligne (id nil).
    func scan(_ id: String? = nil) async throws {
        try await send(id.map { "api/devices/\($0)/scan" } ?? "api/scan", method: "POST")
    }

    func checkUpdates(_ id: String) async throws { try await send("api/devices/\(id)/check-updates", method: "POST") }

    func createPhone(name: String, platform: String, osVersion: String) async throws -> String {
        struct Body: Encodable { let name, platform, osVersion: String }
        struct Created: Decodable { let id: String }
        let data = try await send("api/phones", method: "POST", body: Body(name: name, platform: platform, osVersion: osVersion))
        return try Self.decoder.decode(Created.self, from: data).id
    }

    func answer(device: String, check: String, status: CheckStatus) async throws -> DeviceDetail {
        struct Body: Encodable { let status: String }
        let data = try await send("api/phones/\(device)/checks/\(check)", method: "PUT", body: Body(status: status.rawValue))
        return try Self.decoder.decode(DeviceDetail.self, from: data)
    }

    /// Marque un problème comme risque accepté (ou renouvelle l'acceptation pour 6 mois).
    func accept(device: String, check: String, reason: String) async throws -> DeviceDetail {
        struct Body: Encodable { let reason: String }
        let data = try await send("api/devices/\(device)/checks/\(check)/accept", method: "PUT", body: Body(reason: reason))
        return try Self.decoder.decode(DeviceDetail.self, from: data)
    }

    func unaccept(device: String, check: String) async throws -> DeviceDetail {
        let data = try await send("api/devices/\(device)/checks/\(check)/accept", method: "DELETE")
        return try Self.decoder.decode(DeviceDetail.self, from: data)
    }

    func settings() async throws -> ServerSettings { try await get("api/settings") }

    func saveSettings(_ s: ServerSettings) async throws -> ServerSettings {
        try Self.decoder.decode(ServerSettings.self, from: try await send("api/settings", method: "PUT", body: s))
    }

    func testNotification() async throws { try await send("api/settings/test", method: "POST") }
}

private extension Array where Element == String {
    func splitFirst() -> (String, String?) { (first ?? "", count > 1 ? self[1] : nil) }
}
