package com.apoorvdarshan.verceltics.data.vercel

import com.apoorvdarshan.verceltics.data.account.SecretValue
import com.apoorvdarshan.verceltics.data.network.*
import org.junit.Assert.*
import org.junit.Test

class VercelProjectEditorApiTest {
    private val token = SecretValue.of("test-token")
    private class FakeTransport : ProviderHttpsTransport {
        val requests = mutableListOf<ProviderHttpsRequest>()
        var status = 200
        var response = "{}"
        override fun newCall(request: ProviderHttpsRequest): CancelableCall<HttpResponse> {
            requests += request
            return object : CancelableCall<HttpResponse> {
                override fun execute() = HttpResponse(status, response.toByteArray(), emptyMap())
                override fun cancel() = Unit
            }
        }
    }

    @Test fun settingsUsePatchAndKeepDefaultResetsAndTeamScope() {
        val transport = FakeTransport()
        VercelProjectEditorApi(transport).change(token, "prj_123", "team_456",
            VercelProjectChange.Settings(VercelEditableProject("new-name", null, "npm ci", "dist", null))).execute()
        val request = transport.requests.single()
        assertEquals("PATCH", request.method)
        assertEquals("api.vercel.com", request.uri.host)
        assertEquals("/v9/projects/prj_123", request.uri.path)
        assertEquals("teamId=team_456", request.uri.query)
        val json = ProviderJsonParser.parse(request.peekBody()!!)
        assertEquals(ProviderJsonValue.Null, json["buildCommand"])
        assertEquals("npm ci", json["installCommand"]?.stringValue)
        assertSame(token, request.bearerToken)
        assertFalse(request.toString().contains("test-token"))
    }

    @Test fun environmentCreateSupportsMultilineWithoutExposingValues() {
        val transport = FakeTransport()
        val change = VercelProjectChange.SaveEnvironment(null, "PRIVATE_KEY", "line1\nline2", listOf("preview"))
        VercelProjectEditorApi(transport).change(token, "prj_123", null, change).execute()
        val request = transport.requests.single()
        assertEquals("POST", request.method)
        assertEquals("/v10/projects/prj_123/env", request.uri.path)
        assertEquals("line1\nline2", ProviderJsonParser.parse(request.peekBody()!!)["value"]?.stringValue)
        assertFalse(request.toString().contains("line1"))
        assertFalse(change.toString().contains("line1"))
    }

    @Test fun environmentReadsDiscardValuesAndPreserveScopeMetadata() {
        val transport = FakeTransport().apply {
            response = """{"envs":[{"id":"env_1","key":"TOKEN","value":"do-not-show","type":"encrypted","target":["preview"],"gitBranch":"feature","customEnvironmentIds":["env_custom"]}]}"""
        }
        val result = VercelProjectEditorApi(transport).environments(token, "prj_123", "team_456").execute().single()
        assertEquals("feature", result.gitBranch)
        assertEquals(listOf("env_custom"), result.customEnvironmentIds)
        assertFalse(result.toString().contains("do-not-show"))
        assertTrue(transport.requests.single().uri.query.contains("decrypt=false"))
    }

    @Test fun environmentUpdateAndDeleteUseTheirDocumentedPaths() {
        val transport = FakeTransport()
        val api = VercelProjectEditorApi(transport)
        api.change(token, "prj_123", null, VercelProjectChange.SaveEnvironment("env_1", "TOKEN", "", listOf("production"))).execute()
        api.change(token, "prj_123", null, VercelProjectChange.DeleteEnvironment("env_1")).execute()
        assertEquals(listOf("PATCH", "DELETE"), transport.requests.map { it.method })
        assertTrue(transport.requests.all { it.uri.path == "/v9/projects/prj_123/env/env_1" })
        assertNull(transport.requests.last().peekBody())
    }

    @Test fun domainBindingNormalizesNamesAndDeletionHasNoBody() {
        val transport = FakeTransport()
        val api = VercelProjectEditorApi(transport)
        api.change(token, "prj_123", null, VercelProjectChange.AddDomain("Example.COM")).execute()
        api.change(token, "prj_123", null, VercelProjectChange.RemoveDomain("Example.COM")).execute()
        assertEquals("/v10/projects/prj_123/domains", transport.requests.first().uri.path)
        assertEquals("example.com", ProviderJsonParser.parse(transport.requests.first().peekBody()!!)["name"]?.stringValue)
        assertEquals("DELETE", transport.requests.last().method)
        assertEquals("/v9/projects/prj_123/domains/example.com", transport.requests.last().uri.path)
    }

    @Test fun invalidPathsAndDomainsNeverCreateRequests() {
        val transport = FakeTransport()
        val api = VercelProjectEditorApi(transport)
        assertThrows(IllegalArgumentException::class.java) { api.settings(token, "../other", null) }
        assertThrows(IllegalArgumentException::class.java) { api.change(token, "prj_123", null, VercelProjectChange.AddDomain("https://evil.example/path")) }
        assertThrows(IllegalArgumentException::class.java) { api.change(token, "prj_123", null, VercelProjectChange.SaveEnvironment(null, "KEY", "secret", listOf("other"))) }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun permissionErrorsNeverEchoProviderSecrets() {
        val transport = FakeTransport().apply { status = 403; response = """{"error":{"message":"secret-value"}}""" }
        val error = assertThrows(IllegalStateException::class.java) {
            VercelProjectEditorApi(transport).change(token, "prj_123", null, VercelProjectChange.DeleteEnvironment("env_1")).execute()
        }
        assertTrue(error.message!!.contains("permission"))
        assertFalse(error.message!!.contains("secret-value"))
    }

    @Test fun unverifiedDomainsRemainVisible() {
        val transport = FakeTransport().apply { response = """{"domains":[{"name":"example.com","verified":false}]}""" }
        assertFalse(VercelProjectEditorApi(transport).domains(token, "prj_123", null).execute().single().verified)
    }
}
