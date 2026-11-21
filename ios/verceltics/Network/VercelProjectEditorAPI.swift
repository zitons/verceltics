import Foundation

nonisolated struct VercelEditableProject: Codable, Equatable, Sendable {
    var name: String
    var buildCommand: String?
    var installCommand: String?
    var outputDirectory: String?
    var rootDirectory: String?

    enum CodingKeys: String, CodingKey {
        case name, buildCommand, installCommand, outputDirectory, rootDirectory
    }

    // Null explicitly restores the provider default instead of leaving the old value unchanged.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(buildCommand, forKey: .buildCommand)
        try values.encode(installCommand, forKey: .installCommand)
        try values.encode(outputDirectory, forKey: .outputDirectory)
        try values.encode(rootDirectory, forKey: .rootDirectory)
    }
}

/// Deliberately excludes the API's `value` field, including for plain-text variables.
nonisolated struct VercelEditableEnvironment: Decodable, Identifiable, Sendable {
    let id: String
    let key: String
    let target: [String]
    let type: String
    let gitBranch: String?
    let customEnvironmentIds: [String]

    enum CodingKeys: String, CodingKey { case id, key, target, type, gitBranch, customEnvironmentIds }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        key = try values.decode(String.self, forKey: .key)
        type = try values.decode(String.self, forKey: .type)
        target = try values.decodeIfPresent([String].self, forKey: .target) ?? []
        gitBranch = try values.decodeIfPresent(String.self, forKey: .gitBranch)
        customEnvironmentIds = try values.decodeIfPresent([String].self, forKey: .customEnvironmentIds) ?? []
    }

    var canEdit: Bool {
        ["encrypted", "plain", "sensitive"].contains(type) && !target.isEmpty
            && gitBranch == nil && customEnvironmentIds.isEmpty
    }

    var scopeDescription: String {
        (target + (gitBranch.map { ["Branch: \($0)"] } ?? []) + customEnvironmentIds).joined(separator: ", ")
    }
}

nonisolated struct VercelEditableDomain: Decodable, Identifiable, Sendable {
    let name: String
    let verified: Bool
    var id: String { name }
    enum CodingKeys: String, CodingKey { case name, verified }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        verified = try values.decodeIfPresent(Bool.self, forKey: .verified) ?? false
    }
}

nonisolated struct VercelEnvironmentUpdate: Encodable, Sendable, CustomStringConvertible {
    let key: String
    let value: String
    let target: [String]
    let type: String
    var description: String { "VercelEnvironmentUpdate(key: \(key), value: <redacted>)" }
}

nonisolated enum VercelEditorMutation: Sendable, CustomStringConvertible {
    case settings(VercelEditableProject)
    case saveEnvironment(id: String?, update: VercelEnvironmentUpdate)
    case deleteEnvironment(VercelEditableEnvironment)
    case addDomain(String)
    case removeDomain(String)

    var description: String { "VercelEditorMutation(<redacted>)" }
    var isDeletion: Bool {
        switch self { case .deleteEnvironment, .removeDomain: true; default: false }
    }
    var confirmation: String {
        switch self {
        case .settings(let settings):
            return "Save project settings?\nName: \(settings.name)\nBuild: \(settings.buildCommand ?? "Default")\nInstall: \(settings.installCommand ?? "Default")\nOutput: \(settings.outputDirectory ?? "Default")\nRoot: \(settings.rootDirectory ?? "Default")"
        case .saveEnvironment(let id, let update):
            return "\(id == nil ? "Add" : "Replace") variable \(update.key) for \(update.target.joined(separator: ", "))?\n\(update.value.isEmpty ? "The new value is empty." : "The new value is hidden.")"
        case .deleteEnvironment(let entry):
            return "Delete variable \(entry.key) (\(entry.scopeDescription))?"
        case .addDomain(let domain):
            return "Bind \(domain) to this project?"
        case .removeDomain(let domain):
            return "Remove \(domain) from this project? Traffic on this domain may be affected."
        }
    }
    var successMessage: String {
        switch self {
        case .settings: "Project settings saved. Build changes apply to future deployments."
        case .saveEnvironment, .deleteEnvironment: "Variable saved. Redeploy to apply the change."
        case .addDomain: "Domain added. Check its verification status below."
        case .removeDomain: "Domain removed."
        }
    }
}

nonisolated enum VercelEditorError: LocalizedError {
    case invalidInput(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        case .http(401): "Vercel rejected this token. Reconnect your account."
        case .http(403): "This token or team role does not have permission to make this change."
        case .http(409): "This name or resource already exists. Refresh and try again."
        case .http(429): "Vercel rate limit reached. Wait before trying again."
        case .http(let status): "Vercel request failed (HTTP \(status)). Check the input and refresh before retrying."
        }
    }
}

actor VercelProjectEditorAPI {
    private let token: String
    init(token: String) { self.token = token }

    func settings(projectID: String, teamID: String?) async throws -> VercelEditableProject {
        let request = try Self.request(token: token, method: "GET", path: "/v9/projects/\(Self.segment(projectID))", teamID: teamID)
        return try JSONDecoder().decode(VercelEditableProject.self, from: await data(for: request))
    }

    func environments(projectID: String, teamID: String?) async throws -> [VercelEditableEnvironment] {
        let request = try Self.request(token: token, method: "GET", path: "/v10/projects/\(Self.segment(projectID))/env", teamID: teamID,
                                       query: [URLQueryItem(name: "decrypt", value: "false")])
        let result = try JSONDecoder().decode(EnvironmentResponse.self, from: await data(for: request))
        return result.envs
    }

    func domains(projectID: String, teamID: String?) async throws -> [VercelEditableDomain] {
        let request = try Self.request(token: token, method: "GET", path: "/v9/projects/\(Self.segment(projectID))/domains", teamID: teamID,
                                       query: [URLQueryItem(name: "limit", value: "100")])
        let result = try JSONDecoder().decode(DomainsResponse.self, from: await data(for: request))
        guard result.pagination?.next == nil else {
            throw VercelEditorError.invalidInput("This project has more than 100 domains. Manage its full domain list in Vercel.")
        }
        return result.domains
    }

    func mutate(projectID: String, teamID: String?, change: VercelEditorMutation) async throws {
        let request = try Self.mutationRequest(token: token, projectID: projectID, teamID: teamID, change: change)
        _ = try await data(for: request)
    }

    // Pure request construction also allows XCTest to verify writes without contacting Vercel.
    nonisolated static func mutationRequest(token: String, projectID: String, teamID: String?, change: VercelEditorMutation) throws -> URLRequest {
        let project = "/v9/projects/\(try segment(projectID))"
        let encoder = JSONEncoder()
        switch change {
        case .settings(let settings):
            guard matches(settings.name, "[a-z0-9][a-z0-9._-]{0,99}"), !settings.name.contains("---") else {
                throw VercelEditorError.invalidInput("Enter a valid lowercase project name (up to 100 characters).")
            }
            return try request(token: token, method: "PATCH", path: project, teamID: teamID, body: encoder.encode(settings))
        case .saveEnvironment(let id, let update):
            guard matches(update.key, "[A-Za-z_][A-Za-z0-9_]*"), !update.target.isEmpty,
                  update.target.allSatisfy({ ["production", "preview", "development"].contains($0) }),
                  ["encrypted", "plain", "sensitive"].contains(update.type),
                  !(update.type == "sensitive" && update.target.contains("development")),
                  update.value.utf8.count <= 65_536, !update.value.contains("\0") else {
                throw VercelEditorError.invalidInput("Check the variable name, value and selected environments. Sensitive variables cannot target development.")
            }
            let path: String
            if let id { path = project + "/env/\(try segment(id))" }
            else { path = "/v10/projects/\(try segment(projectID))/env" }
            return try request(token: token, method: id == nil ? "POST" : "PATCH", path: path, teamID: teamID, body: encoder.encode(update))
        case .deleteEnvironment(let entry):
            return try request(token: token, method: "DELETE", path: project + "/env/\(try segment(entry.id))", teamID: teamID)
        case .addDomain(let domain):
            return try request(token: token, method: "POST", path: "/v10/projects/\(try segment(projectID))/domains", teamID: teamID,
                               body: encoder.encode(["name": try domainName(domain)]))
        case .removeDomain(let domain):
            return try request(token: token, method: "DELETE", path: project + "/domains/\(try domainName(domain))", teamID: teamID)
        }
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await ProviderRequestSecurity.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // Provider validation errors may echo secrets, so only status-based errors reach the UI.
        guard (200..<300).contains(response.statusCode) else { throw VercelEditorError.http(response.statusCode) }
        return data
    }

    nonisolated private static func request(token: String, method: String, path: String, teamID: String?,
                                           query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw VercelEditorError.http(401) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.vercel.com"
        components.path = path
        var items = query
        if let teamID { items.append(URLQueryItem(name: "teamId", value: teamID)) }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        return request
    }

    nonisolated private static func segment(_ value: String) throws -> String {
        guard matches(value, "[A-Za-z0-9_-]+") else { throw VercelEditorError.invalidInput("Invalid Vercel resource identifier.") }
        return value
    }
    nonisolated private static func domainName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.utf8.count <= 253, name.contains("."),
              name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  $0.utf8.count <= 63 && matches(String($0), "[a-z0-9](?:[a-z0-9-]*[a-z0-9])?")
              }) else { throw VercelEditorError.invalidInput("Enter a domain name without a URL or path. Use punycode for international domains.") }
        return name
    }
    nonisolated private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:\(pattern))\\z", options: .regularExpression) != nil
    }

    nonisolated private struct EnvironmentResponse: Decodable { let envs: [VercelEditableEnvironment] }
    nonisolated private struct DomainsResponse: Decodable {
        let domains: [VercelEditableDomain]
        let pagination: Pagination?
        nonisolated struct Pagination: Decodable { let next: Int64? }
    }
}

extension Notification.Name {
    static let vercelProjectDidChange = Notification.Name("vercelProjectDidChange")
}
