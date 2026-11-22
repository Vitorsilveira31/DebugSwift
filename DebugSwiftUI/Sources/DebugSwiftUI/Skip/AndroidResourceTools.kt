package debug.swift.android

import android.content.Context
import android.webkit.CookieManager
import android.security.keystore.KeyInfo
import java.io.File
import java.security.KeyStore
import java.security.KeyFactory
import java.security.PrivateKey
import java.util.zip.ZipFile
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import org.json.JSONArray
import org.json.JSONObject
import okhttp3.Call

// Resource tools: persistent data, preferences, files and the security audit.
// Part of AndroidDebugTools: these extensions use the object's state, which lives in AndroidDebugTools.kt.

internal fun AndroidDebugTools.resourcesSnapshot(context: Context, featureID: String): String {
    return when (featureID) {
        "files" -> browseFiles(context, currentFilePath)
        "preferences" -> registeredPreferences.joinToString("\n\n") { name ->
            val values = context.getSharedPreferences(name, Context.MODE_PRIVATE).all
            "$name (${values.size} values)\n" + values.entries.joinToString("\n") { "${it.key} = ${safeValue(it.value)}" }
        }.ifEmpty { "No host preferences registered. Call AndroidDebugTools.registerPreferences(name) during app startup." }
        "persistent_data" -> persistentDataSnapshot(context)
        "keychain" -> {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            "Android Keystore aliases:\n" + store.aliases().toList().joinToString("\n").ifEmpty { "none" } + "\nPrivate key and secret bytes are not exported."
        }
        "realm" -> "Registered Realm databases:\n${DebugSwiftRealmRegistry.snapshot()}\n\nSQLite files:\n${DebugSwiftDatabaseBrowser.databaseNames(context).joinToString("\n").ifEmpty { "none" }}"
        "sqlite", "core_data", "swift_data" -> {
            val dbs = DebugSwiftDatabaseBrowser.databaseNames(context).map { name ->
                val file = context.getDatabasePath(name)
                val tables = runCatching { DebugSwiftDatabaseBrowser.tables(context, name).joinToString() }.getOrDefault("unavailable")
                "$name (${formatBytes(file.length())})\nTables: ${tables.ifEmpty { "none" }}"
            }
            "SQLite/Room databases in this app:\n" + dbs.joinToString("\n").ifEmpty { "No app databases found." } +
                "\n\nRoom databases use SQLite files. Register external or custom database names to enable browsing."
        }
        "cookies" -> {
            val values = webViewHosts.mapNotNull { host -> CookieManager.getInstance().getCookie("https://$host")?.let { "$host\n$it" } }
            values.joinToString("\n\n").ifEmpty { "No cookies available for reported host-app WebView domains." }
        }
        "security_audit" -> securityAudit(context)
        else -> "No resources found."
    }
}

internal fun AndroidDebugTools.persistentDataSnapshot(context: Context): String {
    val preferenceDirectory = File(context.applicationInfo.dataDir, "shared_prefs")
    val preferenceNames = (registeredPreferences + preferenceDirectory.listFiles()
        .orEmpty()
        .filter { it.isFile && it.extension.equals("xml", ignoreCase = true) }
        .map { it.nameWithoutExtension }).toSet()
    val preferences = preferenceNames.sorted().joinToString("\n\n") { name ->
        val values = context.getSharedPreferences(name, Context.MODE_PRIVATE).all
        "$name (${values.size} values)\n" +
            values.entries.sortedBy { it.key }.joinToString("\n") { "${it.key} = ${safeValue(it.value)}" }.ifEmpty { "empty" }
    }.ifEmpty { "No preference stores found." }
    val aliases = runCatching {
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.aliases().toList().sorted()
    }.getOrDefault(emptyList())
    return "App preferences (SharedPreferences)\n$preferences\n\n" +
        "Secure storage (Android Keystore)\n" + aliases.joinToString("\n").ifEmpty { "No aliases found." } +
        "\nPrivate key and secret bytes are not exported. Use Preferences to add, remove, or clear values in registered stores."
}

internal fun AndroidDebugTools.securityAuditReport(context: Context): SecurityAuditReport {
    val sensitiveName = Regex("password|secret|token|credential|api.?key|key", RegexOption.IGNORE_CASE)
    val criticalFindings = linkedSetOf<SecurityAuditFinding>()
    val warningFindings = linkedSetOf<SecurityAuditFinding>()

    val preferenceDirectory = File(context.applicationInfo.dataDir, "shared_prefs")
    val preferenceNames = (registeredPreferences + preferenceDirectory.listFiles()
        .orEmpty()
        .filter { it.isFile && it.extension.equals("xml", ignoreCase = true) }
        .map { it.nameWithoutExtension }).toSet()
    preferenceNames.forEach { name ->
        context.getSharedPreferences(name, Context.MODE_PRIVATE).all.forEach { (key, value) ->
            if (sensitiveName.containsMatchIn(key) && value is String && value.isNotEmpty()) {
                warningFindings.add(SecurityAuditFinding(
                    severity = "warning",
                    source = "preferences",
                    key = "$name:$key",
                    message = "Sensitive key has a non-empty string value in app preferences."
                ))
            }
        }
    }

    val manifestMetadata = runCatching {
        context.packageManager.getApplicationInfo(
            context.packageName,
            android.content.pm.PackageManager.GET_META_DATA
        ).metaData
    }.getOrNull()
    manifestMetadata?.keySet()?.forEach { key ->
        val value = manifestMetadata.get(key)
        if (sensitiveName.containsMatchIn(key) && value is String && value.isNotEmpty()) {
            warningFindings.add(SecurityAuditFinding(
                severity = "warning",
                source = "manifest",
                key = key,
                message = "Sensitive key has a non-empty string value in manifest metadata."
            ))
        }
    }

    val bundleFiles = linkedSetOf<String>()
    val apkPaths = mutableListOf(context.applicationInfo.sourceDir)
    context.applicationInfo.splitSourceDirs?.forEach(apkPaths::add)
    apkPaths.forEach { apkPath ->
        runCatching {
            ZipFile(apkPath).use { apk ->
                apk.entries().asSequence()
                    .filter { entry ->
                        !entry.isDirectory && (entry.name.startsWith("assets/") || entry.name.startsWith("res/raw/"))
                    }
                    .forEach { bundleFiles.add(it.name) }
            }
        }
    }
    val credentialExtensions = setOf("cer", "p12", "mobileconfig", "pem", "key")
    bundleFiles.forEach { path ->
        if (credentialExtensions.contains(path.substringAfterLast('.', "").lowercase())) {
            criticalFindings.add(SecurityAuditFinding(
                severity = "critical",
                source = "bundle",
                key = path,
                message = "Credential file is packaged with the app."
            ))
        }
    }

    var filesScanned = 0
    context.filesDir.walkTopDown().filter { it.isFile }.take(200).forEach { file ->
        if (file.length() > 256_000 || file.extension.lowercase() in setOf("db", "sqlite", "png", "jpg", "jpeg", "webp", "zip", "so")) return@forEach
        filesScanned++
        if (sensitiveName.containsMatchIn(file.name)) {
            warningFindings.add(SecurityAuditFinding(
                severity = "warning",
                source = "privateFile",
                key = file.relativeTo(context.filesDir).path,
                message = "Private file has a sensitive-looking filename."
            ))
        }
        val content = runCatching { file.readText() }.getOrNull() ?: return@forEach
        if ('\u0000' in content) return@forEach
            Regex("(password|secret|token|credential|private.?key)[\\\"']?\\s*[:=]", RegexOption.IGNORE_CASE)
                .findAll(content).take(20).forEach { match ->
                warningFindings.add(SecurityAuditFinding(
                    severity = "warning",
                    source = "privateFile",
                    key = file.relativeTo(context.filesDir).path,
                    message = "Contains a ${match.groupValues[1]} assignment."
                ))
            }
    }

    val keyStorePolicies = runCatching {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        store.aliases().toList().mapNotNull { alias ->
            val key = runCatching { store.getKey(alias, null) }.getOrNull() ?: return@mapNotNull null
            val keySpec = when (key) {
                is SecretKey -> runCatching {
                    SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
                        .getKeySpec(key, KeyInfo::class.java)
                }.getOrNull()
                is PrivateKey -> runCatching {
                    KeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
                        .getKeySpec(key, KeyInfo::class.java)
                }.getOrNull()
                else -> null
            }
            alias to (keySpec as? KeyInfo)
        }
    }.getOrDefault(emptyList())
    val keyStoreFindings = keyStorePolicies.mapNotNull { (alias, info) ->
        if (info != null && !info.isUserAuthenticationRequired()) {
            SecurityAuditFinding(
                severity = "info",
                source = "keyStore",
                key = alias,
                message = "Key use does not require user authentication."
            )
        } else {
            null
        }
    }
    val findings = (criticalFindings + warningFindings + keyStoreFindings).take(300)
    val scannedDetails = "Scanned ${preferenceNames.size} preference stores, ${manifestMetadata?.size() ?: 0} manifest metadata entries, ${bundleFiles.size} bundled files, $filesScanned private text files, and ${keyStorePolicies.size} Android Keystore key policies."
    val summary = "Potentially sensitive references: ${findings.size} · ${criticalFindings.size} critical · ${warningFindings.size} warnings · ${keyStoreFindings.size} info.\n$scannedDetails Matched values are never displayed."
    return SecurityAuditReport(findings, summary, scannedDetails)
}

internal fun AndroidDebugTools.securityAuditSnapshotJSON(context: Context): String {
    val report = securityAuditReport(context)
    val findings = JSONArray()
    report.findings.forEach { finding ->
        findings.put(JSONObject()
            .put("severity", finding.severity)
            .put("source", finding.source)
            .put("key", finding.key)
            .put("message", finding.message))
    }
    return JSONObject()
        .put("findings", findings)
        .put("summary", report.summary)
        .toString()
}

internal fun AndroidDebugTools.securityAudit(context: Context): String {
    val report = securityAuditReport(context)
    val critical = report.findings("critical")
    val warnings = report.findings("warning")
    val info = report.findings("info")
    fun format(findings: List<SecurityAuditFinding>): String = findings.joinToString("\n") {
        "${it.source} · ${it.key} — ${it.message}"
    }
    return "Potentially sensitive references: ${report.findings.size}\n\n" +
        "Critical (${critical.size})\n" + format(critical).ifEmpty { "No credential files found in the app bundle." } +
        "\n\nWarning (${warnings.size})\n" + format(warnings).ifEmpty { "No sensitive keys or assignments found in scanned preferences, manifest metadata, or private text files." } +
        "\n\nInfo (${info.size})\n" + format(info).ifEmpty { "No Android Keystore keys without user-authentication requirements were reported." } +
        "\n\n${report.scannedDetails}\n" +
        "The audit reports key names and file paths only; it never displays matched values."
}

/** The shared editor's JSON, {"store", "key", "value"}, so a key may hold "=" or "|"; null for the text form. */
internal fun AndroidDebugTools.preferencePayload(value: String): Triple<String, String, String?>? {
    if (!value.startsWith("{")) return null
    val json = runCatching { JSONObject(value) }.getOrNull() ?: return Triple("", "", null)
    return Triple(json.optString("store"), json.optString("key"), if (json.has("value")) json.optString("value") else null)
}

internal fun AndroidDebugTools.writePreference(context: Context, value: String): String {
    val payload = preferencePayload(value)
    val storeName: String
    val key: String
    val rawValue: String
    if (payload != null) {
        if (payload.second.isEmpty() || payload.third == null) return "Enter a key and a value."
        storeName = payload.first
        key = payload.second
        rawValue = payload.third!!
    } else {
        val parts = value.split("|", limit = 2)
        if (parts.size != 2) return "Enter preferenceStore|key=value."
        val assignment = parts[1].split("=", limit = 2)
        if (assignment.size != 2 || assignment[0].isBlank()) return "Enter preferenceStore|key=value."
        storeName = parts[0].trim()
        key = assignment[0].trim()
        rawValue = assignment[1]
    }
    if (!isEditablePreferenceStore(context, storeName)) return "Choose one of the app's preference stores."
    val store = context.getSharedPreferences(storeName, Context.MODE_PRIVATE)
    val current = store.all[key]
    val editor = store.edit()
    when (current) {
        is Boolean -> editor.putBoolean(key, rawValue.toBooleanStrictOrNull() ?: return "'$key' is a Boolean preference; enter true or false.")
        is Int -> editor.putInt(key, rawValue.toIntOrNull() ?: return "'$key' is an integer preference; enter a whole number.")
        is Long -> editor.putLong(key, rawValue.toLongOrNull() ?: return "'$key' is a long integer preference; enter a whole number.")
        is Float -> editor.putFloat(key, rawValue.toFloatOrNull() ?: return "'$key' is a numeric preference; enter a number.")
        is Set<*> -> editor.putStringSet(key, rawValue.split(',').map { it.trim() }.toMutableSet())
        is String -> editor.putString(key, rawValue)
        else -> when {
            rawValue.equals("true", ignoreCase = true) || rawValue.equals("false", ignoreCase = true) -> editor.putBoolean(key, rawValue.toBoolean())
            rawValue.toIntOrNull() != null -> editor.putInt(key, rawValue.toInt())
            rawValue.toLongOrNull() != null -> editor.putLong(key, rawValue.toLong())
            else -> editor.putString(key, rawValue)
        }
    }
    editor.apply()
    publishEvent("resources", "Preference updated: $storeName.$key")
    return "Preference updated."
}

internal fun AndroidDebugTools.deletePreference(context: Context, value: String): String {
    val payload = preferencePayload(value)
    val storeName: String
    val key: String
    if (payload != null) {
        if (payload.first.isBlank() || payload.second.isEmpty()) return "Enter preferenceStore|key."
        storeName = payload.first
        key = payload.second
    } else {
        val parts = value.split("|", limit = 2)
        if (parts.size != 2 || parts[0].isBlank() || parts[1].isBlank()) return "Enter preferenceStore|key."
        storeName = parts[0].trim()
        key = parts[1].trim()
    }
    if (!isEditablePreferenceStore(context, storeName)) {
        return "Choose one of the app's preference stores."
    }
    val store = context.getSharedPreferences(storeName, Context.MODE_PRIVATE)
    if (key !in store.all) return "Preference '$key' was not found in '$storeName'."
    store.edit().remove(key).apply()
    publishEvent("resources", "Preference removed: $storeName.$key")
    return "Preference '$key' removed from '$storeName'."
}

internal fun AndroidDebugTools.clearPreferenceStore(context: Context, value: String): String {
    val parts = value.split("|", limit = 2)
    if (parts.size != 2 || parts[1].trim() != "CLEAR") {
        return "Enter preferenceStore|CLEAR to confirm removing all values from a store."
    }
    val storeName = parts[0].trim()
    if (!isEditablePreferenceStore(context, storeName)) {
        return "Choose one of the app's preference stores."
    }
    val store = context.getSharedPreferences(storeName, Context.MODE_PRIVATE)
    val removedCount = store.all.size
    store.edit().clear().apply()
    publishEvent("resources", "Preference store cleared: $storeName")
    return "Cleared $removedCount values from '$storeName'."
}

internal fun AndroidDebugTools.listFiles(directory: File): String = directory.listFiles()?.sortedBy { it.name }?.take(100)?.joinToString("\n") {
    val suffix = if (it.isDirectory) "/" else " (${formatBytes(it.length())})"
    it.name + suffix
}?.ifEmpty { "empty" } ?: "unavailable"

internal fun AndroidDebugTools.browseFiles(context: Context, path: String): String {
    val normalized = path.trim().trimStart('/')
    val rootName = normalized.substringBefore('/').ifEmpty { "files" }
    val root = when (rootName) {
        "files" -> context.filesDir
        "cache" -> context.cacheDir
        "databases" -> File(context.applicationInfo.dataDir, "databases")
        else -> return "Choose an app-private root: files/, cache/, or databases/."
    }.canonicalFile
    val relative = normalized.substringAfter('/', "")
    val target = File(root, relative).canonicalFile
    if (target != root && !target.path.startsWith(root.path + File.separator)) {
        return "The file browser is limited to the app's private files, cache, and databases."
    }
    currentFilePath = if (relative.isEmpty()) rootName else "$rootName/$relative"
    if (target.isDirectory) {
        val children = target.listFiles()?.sortedWith(compareBy<File> { !it.isDirectory }.thenBy { it.name })
            ?.take(200)?.joinToString("\n") { file ->
                val kind = if (file.isDirectory) "DIR" else "FILE"
                val size = if (file.isFile) " · ${formatBytes(file.length())}" else ""
                "$kind  ${file.name}$size"
            }.orEmpty()
        return "Path: $currentFilePath\nEnter a child path above and choose Open path to browse it.\n\n${children.ifEmpty { "This directory is empty or unreadable." }}"
    }
    if (!target.isFile) return "Path not found: $currentFilePath"
    if (target.length() > 1_000_000) return "File is ${formatBytes(target.length())}; preview is limited to 1 MB."
    val preview = runCatching { target.readText().take(64_000) }.getOrElse { "Text preview unavailable: ${it.message}" }
    return "Path: $currentFilePath · ${formatBytes(target.length())}\n\n$preview"
}

internal fun AndroidDebugTools.exportCurrentFile(context: Context): File? {
    val path = currentFilePath.trim().trimStart('/')
    val rootName = path.substringBefore('/').ifEmpty { "files" }
    val root = when (rootName) {
        "files" -> context.filesDir
        "cache" -> context.cacheDir
        "databases" -> File(context.applicationInfo.dataDir, "databases")
        else -> return null
    }.canonicalFile
    val source = File(root, path.substringAfter('/', "")).canonicalFile
    if (source != root && !source.path.startsWith(root.path + File.separator)) return null
    if (source.isDirectory) {
        return File(context.cacheDir, "debugswift-files-${System.currentTimeMillis()}.txt").apply {
            writeText(browseFiles(context, path))
        }
    }
    if (!source.isFile) return null
    val destination = File(context.cacheDir, "debugswift-export-${source.name}")
    return runCatching { source.copyTo(destination, overwrite = true) }.getOrNull()
}
