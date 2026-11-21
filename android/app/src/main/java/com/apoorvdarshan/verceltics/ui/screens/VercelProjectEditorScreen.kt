package com.apoorvdarshan.verceltics.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.apoorvdarshan.verceltics.data.vercel.*
import com.apoorvdarshan.verceltics.ui.VercelConnectionViewModel
import com.apoorvdarshan.verceltics.ui.VercelProjectUi
import kotlinx.coroutines.launch

@Composable
internal fun VercelProjectEditorScreen(
    project: VercelProjectUi, accountId: String, viewModel: VercelConnectionViewModel,
    onBack: () -> Unit, onChanged: () -> Unit, modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var tab by remember { mutableIntStateOf(0) }
    var loading by remember { mutableStateOf(true) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var settings by remember { mutableStateOf<VercelEditableProject?>(null) }
    var environments by remember { mutableStateOf<List<VercelEnvironmentEntry>?>(null) }
    var domains by remember { mutableStateOf<List<VercelEditableDomain>?>(null) }
    var refresh by remember { mutableIntStateOf(0) }
    var pending by remember { mutableStateOf<VercelProjectChange?>(null) }
    var confirmation by remember { mutableStateOf("") }
    var environmentId by remember { mutableStateOf<String?>(null) }
    var environmentType by remember { mutableStateOf("encrypted") }
    var variableKey by remember { mutableStateOf("") }
    // Secrets must not enter saved instance state.
    var variableValue by remember { mutableStateOf("") }
    var targets by remember { mutableStateOf(setOf("production")) }
    var domain by remember { mutableStateOf("") }
    BackHandler { if (!saving) onBack() }
    LaunchedEffect(project.id, accountId, tab, refresh) {
        loading = true; error = null
        try {
            when (tab) {
                0 -> viewModel.loadEditorSettings(accountId, project).onSuccess { settings = it }.onFailure { settings = null; error = it.message }
                1 -> viewModel.loadEditorEnvironments(accountId, project).onSuccess { environments = it }.onFailure { environments = null; error = it.message }
                2 -> viewModel.loadEditorDomains(accountId, project).onSuccess { domains = it }.onFailure { domains = null; error = it.message }
            }
        } finally { loading = false }
    }
    fun confirm(change: VercelProjectChange, text: String) { pending = change; confirmation = text; error = null }
    fun clearVariable() { environmentId = null; variableKey = ""; variableValue = ""; environmentType = "encrypted"; targets = setOf("production") }
    pending?.let { change ->
        AlertDialog(
            onDismissRequest = { pending = null }, title = { Text("Confirm Vercel change") },
            text = { Text("Project: ${project.name}\n$confirmation") },
            dismissButton = { TextButton(onClick = { pending = null }) { Text("Cancel") } },
            confirmButton = { TextButton(onClick = {
                pending = null; saving = true; notice = null
                scope.launch {
                    try {
                        viewModel.changeProject(accountId, project, change).onSuccess {
                            notice = "Saved. Environment and build changes apply to future deployments."
                            if (change is VercelProjectChange.SaveEnvironment || change is VercelProjectChange.DeleteEnvironment) clearVariable()
                            domain = ""; onChanged(); refresh++
                        }.onFailure { error = it.message ?: "The change could not be confirmed. Refresh before retrying." }
                    } finally { saving = false }
                }
            }) { Text("Confirm") } },
        )
    }
    Column(modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = onBack, enabled = !saving) { Text("Back") }
            TextButton(onClick = { refresh++ }, enabled = !loading && !saving) { Text("Refresh") }
        }
        Text("Edit ${settings?.name ?: project.name}", style = MaterialTheme.typography.titleLarge)
        Text(project.scope?.name ?: "Personal account", style = MaterialTheme.typography.bodySmall)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
            listOf("Settings", "Variables", "Domains").forEachIndexed { index, label ->
                TextButton(onClick = { tab = index; notice = null }, enabled = !saving && !loading) { Text(if (tab == index) "[$label]" else label) }
            }
        }
        if (loading || saving) LinearProgressIndicator(Modifier.fillMaxWidth())
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(vertical = 8.dp)) }
        notice?.let { Text(it, modifier = Modifier.padding(vertical = 8.dp)) }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val enabled = !loading && !saving
            when (tab) {
                0 -> settings?.let { s ->
                    EditorField("Project name", s.name, enabled) { settings = s.copy(name = it) }
                    EditorField("Build command", s.buildCommand.orEmpty(), enabled) { settings = s.copy(buildCommand = it) }
                    EditorField("Install command", s.installCommand.orEmpty(), enabled) { settings = s.copy(installCommand = it) }
                    EditorField("Output directory", s.outputDirectory.orEmpty(), enabled) { settings = s.copy(outputDirectory = it) }
                    EditorField("Root directory", s.rootDirectory.orEmpty(), enabled) { settings = s.copy(rootDirectory = it) }
                    Text("Clear an optional field to restore its default.")
                    Button(enabled = enabled && s.name.isNotBlank(), onClick = {
                        val updated = s.copy(name = s.name.trim(), buildCommand = s.buildCommand?.takeIf(String::isNotBlank),
                            installCommand = s.installCommand?.takeIf(String::isNotBlank), outputDirectory = s.outputDirectory?.trim()?.takeIf(String::isNotEmpty),
                            rootDirectory = s.rootDirectory?.trim()?.takeIf(String::isNotEmpty))
                        confirm(VercelProjectChange.Settings(updated), "Save settings:\nName: ${updated.name}\nBuild: ${updated.buildCommand ?: "Default"}\nInstall: ${updated.installCommand ?: "Default"}\nOutput: ${updated.outputDirectory ?: "Default"}\nRoot: ${updated.rootDirectory ?: "Default"}")
                    }) { Text("Save settings") }
                }
                1 -> environments?.let { entries ->
                    Text("Values are hidden. Editing replaces the value. Redeploy to apply changes.")
                    entries.forEach { entry ->
                        Text("${entry.key} | ${entry.targets.joinToString()} | ${entry.type}")
                        if (entry.gitBranch != null) Text("Branch: ${entry.gitBranch}. Edit in Vercel.")
                        if (entry.customEnvironmentIds.isNotEmpty()) Text("Custom environments: ${entry.customEnvironmentIds.joinToString()}. Edit in Vercel.")
                        Row {
                            TextButton(enabled = enabled && entry.type in setOf("encrypted", "plain", "sensitive") && entry.targets.isNotEmpty() && entry.gitBranch == null && entry.customEnvironmentIds.isEmpty(), onClick = {
                                environmentId = entry.id; variableKey = entry.key; variableValue = ""; targets = entry.targets.toSet(); environmentType = entry.type
                            }) { Text("Edit") }
                            TextButton(enabled = enabled, onClick = { confirm(VercelProjectChange.DeleteEnvironment(entry.id), "Delete variable ${entry.key} (${entry.targets.joinToString()})?\nBranch: ${entry.gitBranch ?: "All"}\nCustom environments: ${entry.customEnvironmentIds.joinToString().ifEmpty { "None" }}") }) { Text("Delete") }
                        }
                    }
                    HorizontalDivider()
                    Text(if (environmentId == null) "Add variable" else "Replace variable")
                    EditorField("Variable name", variableKey, enabled) { variableKey = it }
                    OutlinedTextField(value = variableValue, onValueChange = { variableValue = it }, enabled = enabled,
                        label = { Text("New value (may be empty)") }, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                    listOf("production", "preview", "development").forEach { target ->
                        Row {
                            Checkbox(checked = target in targets, enabled = enabled && (environmentType != "sensitive" || target != "development"), onCheckedChange = { checked -> targets = if (checked) targets + target else targets - target })
                            Text(target, modifier = Modifier.padding(top = 12.dp))
                        }
                    }
                    Button(enabled = enabled && variableKey.isNotBlank() && targets.isNotEmpty(), onClick = {
                        confirm(VercelProjectChange.SaveEnvironment(environmentId, variableKey.trim(), variableValue, targets.toList(), environmentType),
                            "${if (environmentId == null) "Add" else "Replace"} variable ${variableKey.trim()} for ${targets.joinToString()}?\n${if (variableValue.isEmpty()) "The new value is empty." else "The new value is hidden."}")
                    }) { Text("Save variable") }
                    if (environmentId != null) TextButton(onClick = { clearVariable() }, enabled = enabled) { Text("Cancel editing") }
                }
                2 -> domains?.let { entries ->
                    Text("Binding a domain may require DNS configuration or ownership verification in Vercel.")
                    entries.forEach { entry ->
                        Text("${entry.name} | ${if (entry.verified) "Verified" else "Verification required"}")
                        TextButton(enabled = enabled, onClick = { confirm(VercelProjectChange.RemoveDomain(entry.name), "Remove ${entry.name} from this project? Traffic on this domain may be affected.") }) { Text("Remove") }
                    }
                    HorizontalDivider()
                    EditorField("Domain (example.com)", domain, enabled) { domain = it }
                    Button(enabled = enabled && domain.isNotBlank(), onClick = { confirm(VercelProjectChange.AddDomain(domain.trim()), "Bind ${domain.trim()} to this project?") }) { Text("Add domain") }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun EditorField(label: String, value: String, enabled: Boolean, onChange: (String) -> Unit) {
    OutlinedTextField(value = value, onValueChange = onChange, enabled = enabled, singleLine = true,
        label = { Text(label) }, modifier = Modifier.fillMaxWidth())
}
