package com.apoorvdarshan.verceltics.data.vercel

import com.apoorvdarshan.verceltics.data.account.SecretValue
import com.apoorvdarshan.verceltics.data.network.*

/** Only editable settings are sent back; credentials and environment values are never returned. */
data class VercelEditableProject(
    val name: String,
    val buildCommand: String?,
    val installCommand: String?,
    val outputDirectory: String?,
    val rootDirectory: String?,
)
data class VercelEnvironmentEntry(val id: String, val key: String, val targets: List<String>, val type: String, val gitBranch: String? = null, val customEnvironmentIds: List<String> = emptyList())
data class VercelEditableDomain(val name: String, val verified: Boolean)

sealed interface VercelProjectChange {
    data class Settings(val settings: VercelEditableProject) : VercelProjectChange
    class SaveEnvironment(val id: String?, val key: String, val value: String, val targets: List<String>, val type: String = "encrypted") : VercelProjectChange
    data class DeleteEnvironment(val id: String) : VercelProjectChange
    data class AddDomain(val name: String) : VercelProjectChange
    data class RemoveDomain(val name: String) : VercelProjectChange
}

class VercelProjectEditorApi(private val transport: ProviderHttpsTransport = SecureProviderHttpsTransport()) {
    fun settings(token: SecretValue, projectId: String, teamId: String?): CancelableCall<VercelEditableProject> =
        call(token, "GET", "/v9/projects/${segment(projectId)}", teamId).map { json ->
            VercelEditableProject(json["name"]?.stringValue.orEmpty(), json["buildCommand"]?.stringValue,
                json["installCommand"]?.stringValue, json["outputDirectory"]?.stringValue, json["rootDirectory"]?.stringValue)
        }

    fun environments(token: SecretValue, projectId: String, teamId: String?): CancelableCall<List<VercelEnvironmentEntry>> =
        call(token, "GET", "/v10/projects/${segment(projectId)}/env", teamId, query = listOf("decrypt" to "false")).map { json ->
            json["envs"]?.arrayValue.orEmpty().map { env ->
                VercelEnvironmentEntry(requireNotNull(env["id"]?.stringValue), requireNotNull(env["key"]?.stringValue),
                    env["target"]?.arrayValue.orEmpty().mapNotNull { it.stringValue }, env["type"]?.stringValue ?: "encrypted", env["gitBranch"]?.stringValue,
                    env["customEnvironmentIds"]?.arrayValue.orEmpty().mapNotNull { it.stringValue })
            }
        }

    fun domains(token: SecretValue, projectId: String, teamId: String?): CancelableCall<List<VercelEditableDomain>> =
        call(token, "GET", "/v9/projects/${segment(projectId)}/domains", teamId, query = listOf("limit" to "100")).map { json ->
            val domains = json["domains"]?.arrayValue.orEmpty()
            check(json["pagination"]?.get("next")?.stringValue == null) { "This project has more than 100 domains. Manage its full domain list in Vercel." }
            domains.map { VercelEditableDomain(requireNotNull(it["name"]?.stringValue), it["verified"]?.booleanValue == true) }
        }

    fun change(token: SecretValue, projectId: String, teamId: String?, change: VercelProjectChange): CancelableCall<Unit> {
        val project = "/v9/projects/${segment(projectId)}"
        val request = when (change) {
            is VercelProjectChange.Settings -> {
                val s = change.settings
                require(Regex("[a-z0-9][a-z0-9._-]{0,99}").matches(s.name) && "---" !in s.name) { "Enter a valid lowercase project name (up to 100 characters)." }
                call(token, "PATCH", project, teamId, jsonObjectOf("name" to s.name,
                    "buildCommand" to s.buildCommand, "installCommand" to s.installCommand,
                    "outputDirectory" to s.outputDirectory, "rootDirectory" to s.rootDirectory))
            }
            is VercelProjectChange.SaveEnvironment -> {
                require(Regex("[A-Za-z_][A-Za-z0-9_]*").matches(change.key)) { "Enter a valid environment variable name." }
                require(change.targets.isNotEmpty() && change.targets.all { it in setOf("production", "preview", "development") }) { "Choose at least one environment." }
                require(change.type in setOf("encrypted", "plain", "sensitive")) { "This variable type must be edited in Vercel." }
                require(change.type != "sensitive" || "development" !in change.targets) { "Sensitive variables cannot target development." }
                require(change.value.length <= 65536 && '\u0000' !in change.value) { "Invalid environment variable value." }
                val payload = jsonObjectOf("key" to change.key, "value" to change.value, "target" to change.targets, "type" to change.type)
                val path = if (change.id == null) "/v10/projects/${segment(projectId)}/env" else "/v9/projects/${segment(projectId)}/env/${segment(change.id)}"
                call(token, if (change.id == null) "POST" else "PATCH", path, teamId, payload)
            }
            is VercelProjectChange.DeleteEnvironment -> call(token, "DELETE", project + "/env/${segment(change.id)}", teamId)
            is VercelProjectChange.AddDomain -> call(token, "POST", "/v10/projects/${segment(projectId)}/domains", teamId, jsonObjectOf("name" to domain(change.name)))
            is VercelProjectChange.RemoveDomain -> call(token, "DELETE", project + "/domains/${domain(change.name)}", teamId)
        }
        return request.map { Unit }
    }

    private fun call(token: SecretValue, method: String, path: String, teamId: String?, body: ProviderJsonValue.Obj? = null,
        query: List<Pair<String, String>> = emptyList()): CancelableCall<ProviderJsonValue> {
        val uri = ProviderEndpointPolicy("https://api.vercel.com").resolve(path, query + listOfNotNull(teamId?.let { "teamId" to it }))
        val bytes = body?.let(ProviderJsonWriter::writeBytes)
        val request = try { ProviderHttpsRequest(method, uri, bearerToken = token, body = bytes) } finally { bytes?.fill(0) }
        return transport.newCall(request).map { response ->
            val data = response.takeBody()
            try {
                if (response.statusCode !in 200..299) {
                    // Do not surface provider response bodies: validation errors can echo secrets.
                    val message = when (response.statusCode) {
                        401 -> "Vercel rejected this token. Reconnect your account."
                        403 -> "This token or team role does not have permission to make this change."
                        409 -> "This name or resource already exists. Refresh and try again."
                        429 -> "Vercel rate limit reached. Wait before trying again."
                        else -> "Vercel request failed (HTTP ${response.statusCode}). Check the input and refresh before retrying."
                    }
                    throw IllegalStateException(message)
                }
                if (data.isEmpty()) ProviderJsonValue.Null else ProviderJsonParser.parse(data)
            } finally { data.fill(0) }
        }
    }

    private fun segment(value: String): String {
        require(Regex("[A-Za-z0-9_-]+").matches(value)) { "Invalid Vercel resource identifier." }
        return value
    }
    private fun domain(value: String): String {
        val name = java.net.IDN.toASCII(value.trim().lowercase())
        require(name.length <= 253 && name.contains('.') && name.split('.').all {
            it.length in 1..63 && Regex("[a-z0-9](?:[a-z0-9-]*[a-z0-9])?").matches(it)
        }) { "Enter a domain name without a URL or path." }
        return name
    }
}
