import XCTest
@testable import verceltics

final class VercelProjectEditorAPITests: XCTestCase {
    func testSettingsUsePatchPreserveTeamScopeAndEncodeNullDefaults() throws {
        let settings = VercelEditableProject(name: "new-name", buildCommand: nil, installCommand: "npm ci", outputDirectory: "dist", rootDirectory: nil)
        let request = try VercelProjectEditorAPI.mutationRequest(token: "test-token", projectID: "prj_123", teamID: "team_456", change: .settings(settings))
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.host, "api.vercel.com")
        XCTAssertEqual(request.url?.path, "/v9/projects/prj_123")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "teamId", value: "team_456")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertTrue(json["buildCommand"] is NSNull)
        XCTAssertTrue(json["rootDirectory"] is NSNull)
        XCTAssertEqual(json["installCommand"] as? String, "npm ci")
    }

    func testEnvironmentCreateUsesV10AndSupportsMultilineValues() throws {
        let update = VercelEnvironmentUpdate(key: "PRIVATE_KEY", value: "line1\nline2", target: ["preview"], type: "encrypted")
        let change = VercelEditorMutation.saveEnvironment(id: nil, update: update)
        let request = try VercelProjectEditorAPI.mutationRequest(token: "test-token", projectID: "prj_123", teamID: nil, change: change)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v10/projects/prj_123/env")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["value"] as? String, "line1\nline2")
        XCTAssertFalse(change.confirmation.contains("line1"))
        XCTAssertFalse(String(describing: change).contains("line1"))
        XCTAssertFalse(String(describing: update).contains("line1"))
    }

    func testEnvironmentUpdateAndDeleteUseV9() throws {
        let update = VercelEnvironmentUpdate(key: "TOKEN", value: "", target: ["production"], type: "encrypted")
        let patch = try VercelProjectEditorAPI.mutationRequest(token: "test-token", projectID: "prj_123", teamID: nil,
                                                             change: .saveEnvironment(id: "env_1", update: update))
        let entry = try JSONDecoder().decode(VercelEditableEnvironment.self, from: Data(#"{"id":"env_1","key":"TOKEN","type":"encrypted","target":["production"]}"#.utf8))
        let deletion = try VercelProjectEditorAPI.mutationRequest(token: "test-token", projectID: "prj_123", teamID: nil, change: .deleteEnvironment(entry))
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertEqual(deletion.httpMethod, "DELETE")
        XCTAssertEqual(patch.url?.path, "/v9/projects/prj_123/env/env_1")
        XCTAssertEqual(deletion.url?.path, patch.url?.path)
        XCTAssertNil(deletion.httpBody)
    }

    func testBranchAndCustomEnvironmentVariablesCannotBeEditedAsStandardVariables() throws {
        let entry = try JSONDecoder().decode(VercelEditableEnvironment.self, from: Data(#"{"id":"env_1","key":"TOKEN","value":"do-not-show","type":"plain","target":["preview"],"gitBranch":"feature","customEnvironmentIds":["env_custom"]}"#.utf8))
        XCTAssertFalse(entry.canEdit)
        XCTAssertEqual(entry.gitBranch, "feature")
        XCTAssertEqual(entry.customEnvironmentIds, ["env_custom"])
        XCTAssertFalse(String(describing: entry).contains("do-not-show"))
        XCTAssertTrue(VercelEditorMutation.deleteEnvironment(entry).confirmation.contains("feature"))
    }

    func testDomainAddAndRemoveUseDocumentedVersionsAndNormalizeNames() throws {
        let add = try VercelProjectEditorAPI.mutationRequest(token: "test-token", projectID: "prj_123", teamID: nil, change: .addDomain("Example.COM"))
        let remove = try VercelProjectEditorAPI.mutationRequest(token: "test-token", projectID: "prj_123", teamID: nil, change: .removeDomain("Example.COM"))
        XCTAssertEqual(add.httpMethod, "POST")
        XCTAssertEqual(add.url?.path, "/v10/projects/prj_123/domains")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(add.httpBody)) as? [String: String])
        XCTAssertEqual(json["name"], "example.com")
        XCTAssertEqual(remove.httpMethod, "DELETE")
        XCTAssertEqual(remove.url?.path, "/v9/projects/prj_123/domains/example.com")
        XCTAssertNil(remove.httpBody)
    }

    func testInvalidIdentifiersAndDomainsCannotEscapeProviderPaths() {
        XCTAssertThrowsError(try VercelProjectEditorAPI.mutationRequest(token: "test-token", projectID: "../other", teamID: nil, change: .addDomain("example.com")))
        for name in ["https://evil.example/path", "example.com?token=x", "example.com.", "a..example.com"] {
            XCTAssertThrowsError(try VercelProjectEditorAPI.mutationRequest(token: "test-token", projectID: "prj_123", teamID: nil, change: .addDomain(name)))
        }
    }

    func testSensitiveVariablesCannotTargetDevelopment() {
        let update = VercelEnvironmentUpdate(key: "TOKEN", value: "secret", target: ["development"], type: "sensitive")
        XCTAssertThrowsError(try VercelProjectEditorAPI.mutationRequest(token: "test-token", projectID: "prj_123", teamID: nil, change: .saveEnvironment(id: nil, update: update)))
    }

    func testUnverifiedDomainsAreNotFilteredOut() throws {
        let domain = try JSONDecoder().decode(VercelEditableDomain.self, from: Data(#"{"name":"example.com","verified":false}"#.utf8))
        XCTAssertFalse(domain.verified)
        XCTAssertEqual(domain.name, "example.com")
    }
}
