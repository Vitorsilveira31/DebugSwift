package debug.swift.example

import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.printToLog
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import android.view.MotionEvent
import debug.swift.android.AndroidDebugTools
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Drives the Example app on a device: the shared SwiftUI demo list and debug panel rendered
 * through Skip Fuse, the Kotlin runtime that Application.onCreate installs, and the bridge
 * between them.
 */
@RunWith(AndroidJUnit4::class)
class DebugSwiftPanelTest {
    /**
     * The app turns on push simulation at launch, which asks for the notification permission on
     * Android 13 and newer. Granting it first keeps the system dialog from covering the app.
     */
    @get:Rule(order = 0)
    val notifications: GrantPermissionRule = if (android.os.Build.VERSION.SDK_INT >= 33) {
        GrantPermissionRule.grant(android.Manifest.permission.POST_NOTIFICATIONS)
    } else {
        GrantPermissionRule.grant()
    }

    @get:Rule(order = 1)
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun homeListsTheDemos() {
        for (demo in listOf("REST API Demo", "Network Injection Testing", "Hang / ANR Demo", "OSLog Console Test")) {
            scrollTo(hasText(demo) and hasClickAction())
        }
    }

    @Test
    fun panelListsTheAreasAndNetworkTools() {
        openPanel()
        for (area in listOf("Network", "Performance", "Interface", "Resources", "App")) {
            scrollTo(hasText(area) and hasClickAction())
        }
        tap(hasText("Network") and hasClickAction())
        scrollTo(hasText("HTTP Inspector") and hasClickAction())
    }

    @Test
    fun consoleShowsTheMessageLoggedFromSwift() {
        // ExampleDebugger.start, run from DebugSwiftExampleAppDelegate.onLaunch, logs this.
        open("App", "Console")
        waitFor(hasText("Example app launched", substring = true))
    }

    @Test
    fun httpInspectorShowsTheRequestWithItsTokenMasked() {
        AndroidDebugTools.recordNetwork(
            method = "GET",
            url = "https://api.example.test/orders?id=42&access_token=secret123",
            status = 200,
            durationMs = 12,
            requestBytes = 0,
            responseBytes = 2,
            requestBody = "",
            responseBody = "{}"
        )
        open("Network", "HTTP Inspector")
        waitFor(hasText("api.example.test/orders?id=42&access_token=%3Credacted%3E", substring = true))
        assertNoNode(hasText("secret123", substring = true))
    }

    @Test
    fun rulesSetFromKotlinMaskThroughDebugSwiftCore() {
        // DebugSwiftNetworkSanitizer hands the rules to DebugSwiftCore over JNI; a key added here is masked there.
        val marker = java.util.UUID.randomUUID().toString().take(8)
        debug.swift.android.DebugSwiftNetworkSanitizer.configure(
            bodyKeys = debug.swift.android.DebugSwiftNetworkSanitizer.defaultBodyKeys + "pin",
            headers = debug.swift.android.DebugSwiftNetworkSanitizer.defaultHeaders + "X-Session"
        )
        try {
            val masked = debug.swift.android.DebugSwiftNetworkSanitizer.sanitize(
                url = "https://user:pw@api.example.test/a?token=t-$marker&page=2",
                requestHeaders = mapOf("X-Session" to listOf("s-$marker"), "Accept" to listOf("a", "b")),
                responseHeaders = emptyMap(),
                requestBody = """{"pin":"1234-$marker","name":"ana"}""",
                responseBody = "",
                decryptedResponseBody = "pin=9-$marker note=kept"
            )
            assertTrue(masked.url, masked.url == "https://user:%3Credacted%3E@api.example.test/a?token=%3Credacted%3E&page=2")
            assertTrue("${masked.requestHeaders}", masked.requestHeaders["X-Session"] == listOf("<redacted>"))
            assertTrue("${masked.requestHeaders}", masked.requestHeaders["Accept"] == listOf("a", "b"))
            assertTrue(masked.requestBody, masked.requestBody.contains(""""pin":"<redacted>"""") && !masked.requestBody.contains(marker))
            assertTrue(masked.decryptedResponseBody, masked.decryptedResponseBody == "pin=<redacted> note=kept")
            // A JSON null leaves password masking on.
            debug.swift.android.DebugSwiftNetworkSanitizer.configureJSON("""{"redactsURLPassword":null}""")
            val stillMasked = debug.swift.android.DebugSwiftNetworkSanitizer.sanitize(
                "https://user:pw@api.example.test/", emptyMap(), emptyMap(), "", "", ""
            )
            assertTrue(stillMasked.url, stillMasked.url == "https://user:%3Credacted%3E@api.example.test/")
        } finally {
            debug.swift.android.DebugSwiftNetworkSanitizer.configure(
                bodyKeys = debug.swift.android.DebugSwiftNetworkSanitizer.defaultBodyKeys,
                headers = debug.swift.android.DebugSwiftNetworkSanitizer.defaultHeaders
            )
        }
    }

    @Test
    fun rewriteRulesMatchURLsThroughDebugSwiftCore() {
        // The same wildcard rules as iOS: a full match of the URL, query items exact and in any order.
        fun matches(url: String, pattern: String, full: Boolean, queryExact: Boolean): Boolean =
            org.json.JSONObject(
                debug.swift.android.DebugSwiftCoreBridge.call(
                    "url.matches",
                    org.json.JSONObject().put("url", url).put("patterns", org.json.JSONArray(listOf(pattern)))
                        .put("full", full).put("queryExact", queryExact).toString()
                )
            ).optBoolean("matches")
        assertTrue(matches("https://api.example.test/orders?b=2&a=1", "*/orders?a=1&b=2", full = true, queryExact = true))
        assertTrue(!matches("https://api.example.test/orders?a=1&b=2&c=3", "*/orders?a=1&b=2", full = true, queryExact = true))
        assertTrue(matches("https://api.example.test/orders?a=1&b=2&c=3", "*/orders?a=1&b=2", full = true, queryExact = false))
        assertTrue(matches("https://api.example.test/v2/orders/42", "orders/*", full = false, queryExact = false))
        assertTrue(!matches("https://api.example.test/v2/orders/42", "orders/*", full = true, queryExact = false))

        val original = AndroidDebugTools.networkInjectionSettingsJSON()
        try {
            val settings = org.json.JSONObject(original)
            settings.getJSONObject("rewrite").put("isEnabled", true).put("rules", org.json.JSONArray().put(
                org.json.JSONObject().put("id", "rule-1").put("urlPattern", "*/profile?id=*").put("responseBody", "{}")
                    .put("isEnabled", true).put("matchType", "wildcard")
            ))
            AndroidDebugTools.applyNetworkInjectionSettingsJSON(settings.toString())
            assertTrue(AndroidDebugTools.matchingNetworkRewriteRule("https://api.example.test/profile?id=7", "GET")?.id == "rule-1")
            assertTrue(AndroidDebugTools.matchingNetworkRewriteRule("https://api.example.test/profile", "GET") == null)
        } finally {
            AndroidDebugTools.applyNetworkInjectionSettingsJSON(original)
        }
    }

    @Test
    fun graphQLLabelsHARAndCURLComeFromDebugSwiftCore() {
        val marker = java.util.UUID.randomUUID().toString().take(8)
        AndroidDebugTools.recordNetwork(
            method = "POST",
            url = "https://api.example.test/graphql-$marker",
            status = 200,
            durationMs = 7,
            requestBytes = 40,
            responseBytes = 12,
            requestBody = """{"query":"query GetUser { user { id } }"}""",
            responseBody = """{"data":{}}""",
            requestHeaders = mapOf("Content-Type" to listOf("application/json"), "Authorization" to listOf("Bearer t")),
            responseHeaders = mapOf("Content-Type" to listOf("application/json"))
        )
        // The label iOS lists for the same request.
        val list = org.json.JSONObject(AndroidDebugTools.networkInspectorSnapshotJSON("graphql")).toString()
        assertTrue(list, list.contains("Query: GetUser"))

        val har = org.json.JSONObject(requireNotNull(AndroidDebugTools.exportHar("http")).readText())
        val entries = har.getJSONObject("log").getJSONArray("entries")
        val entry = (0 until entries.length()).map(entries::getJSONObject)
            .first { it.getJSONObject("request").getString("url").endsWith("graphql-$marker") }
        assertTrue("$entry", entry.getJSONObject("request").getJSONObject("postData").getString("text").contains("GetUser"))
        assertTrue("$entry", entry.getJSONObject("response").getJSONObject("content").getString("text") == """{"data":{}}""")

        val curl = org.json.JSONObject(
            debug.swift.android.DebugSwiftCoreBridge.call(
                "curl.command",
                org.json.JSONObject().put("method", "POST").put("url", "https://api.example.test/a'b")
                    .put("headers", org.json.JSONObject().put("authorization", org.json.JSONArray(listOf("Bearer secret"))))
                    .put("body", "x=1").toString()
            )
        ).getString("command")
        // HTTP field names ignore case: a lowercase `authorization` is masked too.
        assertTrue(curl, curl == "curl -X POST 'https://api.example.test/a'\\''b' -H 'authorization: <redacted>' -d 'x=1'")
    }

    @Test
    fun theAgentSnapshotIsWrittenByDebugSwiftCore() {
        val marker = java.util.UUID.randomUUID().toString().take(8)
        AndroidDebugTools.recordNetwork(
            method = "GET", url = "https://api.example.test/snapshot-$marker?token=abc", status = 503,
            durationMs = 9, requestBytes = 0, responseBytes = 0, requestBody = "", responseBody = "", error = "Service down"
        )
        val reply = AndroidDebugTools.writeAgentSnapshot()
        val snapshot = org.json.JSONObject(java.io.File(reply.getString("path")).readText())
        assertTrue("$snapshot", snapshot.getInt("schemaVersion") == 1 && snapshot.getString("platform") == "android")
        assertTrue("$snapshot", snapshot.getJSONObject("app").getString("bundleId") == "com.debugswift.example")
        val requests = snapshot.getJSONArray("network")
        val request = (0 until requests.length()).map(requests::getJSONObject).last()
        assertTrue("$request", request.getString("url") == "https://api.example.test/snapshot-$marker?token=%3Credacted%3E")
        assertTrue("$request", request.getInt("status") == 503 && request.getString("error") == "Service down")
        assertTrue("$snapshot", snapshot.getJSONObject("agentLog").has("sessionId"))
    }

    @Test
    fun decryptedBodiesAreMaskedLiveAndInSavedHistory() {
        // A decrypted form body whose key is percent-encoded: `pass%77ord` is `password`.
        val marker = java.util.UUID.randomUUID().toString().take(8)
        AndroidDebugTools.recordNetwork(
            method = "GET",
            url = "https://api.example.test/decrypted-$marker",
            status = 200,
            durationMs = 5,
            requestBytes = 0,
            responseBytes = 10,
            requestBody = "",
            responseBody = "ciphertext",
            decryptedResponseBody = "pass%77ord=hunter2-$marker&note=kept-$marker"
        )
        val live = AndroidDebugTools.networkInspectorSnapshotJSON("http")
        assertTrue("This run's request is missing from the inspector", live.contains("decrypted-$marker"))
        assertTrue("The decrypted body lost its other fields", live.contains("kept-$marker"))
        assertTrue("The encoded password reached the inspector: $live", !live.contains("hunter2-$marker"))

        // What a history reload reads back.
        val history = java.io.File(
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.filesDir,
            "debugswift-network-history.json"
        )
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline && !(history.isFile && history.readText().contains("decrypted-$marker"))) {
            Thread.sleep(200)
        }
        val saved = history.readText()
        assertTrue("This run's request was not saved to history", saved.contains("decrypted-$marker"))
        assertTrue("The encoded password reached saved history", !saved.contains("hunter2-$marker"))
    }

    @Test
    fun viewDebuggerGivesTheButtonBackToTheActivityItHid() {
        val main = compose.activity
        compose.runOnUiThread { debug.swift.android.DebugSwiftFloatingButton.setEnabled(main, true) }
        fun mainButton(): android.view.View? =
            (main.window.decorView as android.view.ViewGroup).findViewWithTag("debugswift.floating.button")
        waitUntil("the floating button is on the main Activity") { mainButton() != null }

        // Hold the capture long enough to switch Activities while it is still pending.
        val viewer = debug.swift.android.DebugSwiftViewDebugger3D
        val previousDelay = viewer.captureDelayMs
        viewer.captureDelayMs = 3_000
        try {
            viewer.show()
            waitUntil("the capture hides the main Activity's button") { mainButton()?.visibility == android.view.View.INVISIBLE }

            main.startActivity(android.content.Intent(main, SecondTestActivity::class.java))
            waitUntil("the second Activity is in front") { AndroidDebugTools.foregroundActivityOrNull() is SecondTestActivity }

            // Cancelled while another Activity is in front and before anything was attached.
            viewer.hide()
            (AndroidDebugTools.foregroundActivityOrNull() as? SecondTestActivity)?.finish()
            waitUntil("the main Activity is back in front") { AndroidDebugTools.foregroundActivityOrNull() === main }

            waitUntil("the main Activity's button is visible again") { mainButton()?.visibility == android.view.View.VISIBLE }
            Thread.sleep(3_500)
            assertTrue("The cancelled capture still opened the viewer", !viewer.isShowing)
        } finally {
            viewer.captureDelayMs = previousDelay
            viewer.hide()
            compose.runOnUiThread { debug.swift.android.DebugSwiftFloatingButton.setEnabled(main, false) }
        }
    }

    private fun waitUntil(what: String, timeoutMs: Long = 10_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            var met = false
            compose.runOnUiThread { met = condition() }
            if (met) return
            Thread.sleep(100)
        }
        throw AssertionError("Timed out waiting until $what")
    }

    @Test
    fun aPendingNotificationKeepsItsIdAndRejectionsAreReported() {
        fun simulate(id: String) = org.json.JSONObject(AndroidDebugTools.hostAPI("push.simulate", org.json.JSONObject()
            .put("id", id).put("title", "Pending").put("body", "owned").put("delay", 60).toString()))
        val marker = java.util.UUID.randomUUID().toString().take(8)
        AndroidDebugTools.setPushSimulationEnabled(true)
        try {
            // A pending notification keeps its id after its history entry is cleared: scheduling the
            // id again is rejected, and reported as a failure.
            assertTrue("Scheduling failed", simulate("pending-$marker").optBoolean("ok"))
            AndroidDebugTools.hostAPI("push.clearHistory", "{}")
            val again = simulate("pending-$marker")
            assertTrue("A second schedule took the pending id: $again", !again.optBoolean("ok"))
            assertTrue("The rejection lost its reason: $again", again.optString("message").contains("already exists"))

            // An id with spaces around it is stored as removal and interaction look it up.
            assertTrue("Scheduling a padded id failed", simulate("  padded-$marker  ").optBoolean("ok"))
            assertTrue("The padded id was stored as given", AndroidDebugTools.pushStateJSON().contains("\"padded-$marker\""))
            val removed = AndroidDebugTools.hostAPI("push.remove", org.json.JSONObject().put("id", "padded-$marker").toString())
            assertTrue("Removing the trimmed id failed: $removed", org.json.JSONObject(removed).optBoolean("ok"))
        } finally {
            // Turning simulation off cancels what is pending and frees its ids.
            AndroidDebugTools.setPushSimulationEnabled(false)
            AndroidDebugTools.setPushSimulationEnabled(true)
        }
    }

    @Test
    fun aPreferenceKeyWithEqualsAndBarSignsIsSavedAndDeletedWhole() {
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        val storeName = "debugswift_test_prefs"
        val store = context.getSharedPreferences(storeName, android.content.Context.MODE_PRIVATE)
        val key = "feature=enabled|beta"
        store.edit().putString(key, "on").putString("feature", "untouched").commit()
        fun payload(value: String?) = org.json.JSONObject().put("store", storeName).put("key", key)
            .apply { if (value != null) put("value", value) }.toString()
        try {
            val saved = AndroidDebugTools.perform("preferences", "set_preference", payload("off"))
            assertTrue("Saving answered: $saved", saved == "Preference updated.")
            assertTrue("The key was saved whole", store.getString(key, null) == "off")
            assertTrue("A key named like its prefix is left alone", store.getString("feature", null) == "untouched")
            AndroidDebugTools.perform("preferences", "delete_preference", payload(null))
            assertTrue("The key was deleted", !store.contains(key))
        } finally {
            store.edit().clear().commit()
        }
    }

    @Test
    fun aCookieCanBeDeleted() {
        val manager = android.webkit.CookieManager.getInstance()
        val host = "debugswift-${System.nanoTime()}.test"
        manager.setCookie("https://$host", "session=1")
        manager.setCookie("https://$host", "theme=dark")
        fun names() = manager.getCookie("https://$host").orEmpty().split(';').map { it.trim().substringBefore('=') }.filter { it.isNotEmpty() }
        assertTrue("Both cookies are set: ${names()}", names().containsAll(listOf("session", "theme")))
        val deleted = org.json.JSONObject(
            debug.swift.android.DebugSwiftResourceAPI.handle("cookies.delete", org.json.JSONObject().put("host", host).put("name", "session").toString())
        )
        assertTrue("Deleting answered: $deleted", deleted.optString("message") == "Deleted session.")
        assertTrue("Only session was deleted: ${names()}", names() == listOf("theme"))
        manager.setCookie("https://$host", "theme=; Max-Age=0")

        // A cookie set for the parent domain is seen by the host and deleted there too.
        val parent = "debugswift-parent-${System.nanoTime()}.test"
        manager.setCookie("https://$parent", "shared=1; Domain=$parent; Path=/")
        val child = "api.$parent"
        fun childNames() = manager.getCookie("https://$child").orEmpty().split(';').map { it.trim().substringBefore('=') }
        assertTrue("The subdomain sees the parent's cookie: ${childNames()}", "shared" in childNames())
        val parentDeleted = org.json.JSONObject(
            debug.swift.android.DebugSwiftResourceAPI.handle("cookies.delete", org.json.JSONObject().put("host", child).put("name", "shared").toString())
        )
        assertTrue("Deleting answered: $parentDeleted", parentDeleted.optString("message") == "Deleted shared.")
        assertTrue("The parent's cookie is gone: ${childNames()}", "shared" !in childNames())
    }

    @Test
    fun aFolderListsAllItsEntries() {
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        val folder = java.io.File(context.cacheDir, "debugswift-many-${System.nanoTime()}").apply { mkdirs() }
        try {
            repeat(520) { java.io.File(folder, "file-$it").createNewFile() }
            val listing = org.json.JSONObject(
                debug.swift.android.DebugSwiftResourceAPI.handle("files.list", org.json.JSONObject().put("path", "cache/${folder.name}").toString())
            )
            assertTrue("Listed ${listing.optJSONArray("entries")?.length()} entries", listing.getJSONArray("entries").length() == 520)
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test
    fun aTouchSeenTwiceIsRecordedOnce() {
        AndroidDebugTools.clearDocumentation()
        AndroidDebugTools.setDocumentationRecording(true)
        try {
            val now = android.os.SystemClock.uptimeMillis()
            val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, 100f, 400f, 0)
            val up = MotionEvent.obtain(now, now + 80, MotionEvent.ACTION_UP, 100f, 900f, 0)
            // Two forwarding callbacks pass each event on: once each.
            listOf(down, down, up, up).forEach { AndroidDebugTools.recordTouch(it) }
            down.recycle()
            up.recycle()
            val gestures = org.json.JSONObject(AndroidDebugTools.documentationState()).getJSONArray("gestures")
            assertTrue("Recorded ${gestures.length()} gestures: $gestures", gestures.length() == 1)
            assertTrue("The gesture is the scroll", gestures.getJSONObject(0).getString("kind") == "scroll")
        } finally {
            AndroidDebugTools.setDocumentationRecording(false)
            AndroidDebugTools.clearDocumentation()
        }
    }

    @Test
    fun clearingTheLogHidesWhatWasLoggedBefore() {
        fun log() = debug.swift.android.DebugSwiftAppAPI.handle("app.logcat", org.json.JSONObject().put("filter", "logclear-").put("level", "V").toString())
        val marker = java.util.UUID.randomUUID().toString().take(8)
        android.util.Log.i("DebugSwiftTest", "logclear-before-$marker")
        waitUntil("the first line reaches Logcat") { log().contains("logclear-before-$marker") }
        Thread.sleep(20)
        val cleared = debug.swift.android.DebugSwiftAppAPI.handle("app.logcat.clear", "{}")
        Thread.sleep(20)
        android.util.Log.i("DebugSwiftTest", "logclear-after-$marker")
        waitUntil("the second line reaches Logcat") { log().contains("logclear-after-$marker") }
        val after = log()
        assertTrue("A line from before Clear is still listed: $cleared $after", !after.contains("logclear-before-$marker"))
    }

    @Test
    fun aPatchLeavesAFailureArmedMeanwhile() {
        val original = AndroidDebugTools.networkInjectionSettingsJSON()
        try {
            AndroidDebugTools.failNextNetworkRequest()
            val patched = AndroidDebugTools.hostAPI("network.injection.patch", org.json.JSONObject()
                .put("sections", org.json.JSONObject().put("delay", org.json.JSONObject().put("isEnabled", true).put("fixedDelay", 1)))
                .toString())
            assertTrue("The patch failed: $patched", org.json.JSONObject(patched).optBoolean("ok"))
            val state = AndroidDebugTools.snapshot("network_injection")
            assertTrue("The delay patch disarmed the next failure: $state", state.contains("Fail next request: true"))
        } finally {
            // Replacing the settings as a whole clears the armed failure too.
            AndroidDebugTools.applyNetworkInjectionSettingsJSON(original)
        }
    }

    @Test
    fun simulatedNotificationsKeepTheIdTheyWereGiven() {
        val id = "check-" + java.util.UUID.randomUUID().toString().take(8)
        AndroidDebugTools.setPushSimulationEnabled(true)
        val posted = AndroidDebugTools.hostAPI("push.simulate", org.json.JSONObject()
            .put("id", id).put("title", "Id check").put("body", "kept").put("delay", 60).toString())
        assertTrue("Posting failed: $posted", org.json.JSONObject(posted).optBoolean("ok"))
        assertTrue("The history lost the id", AndroidDebugTools.pushStateJSON().contains(id))

        val removed = AndroidDebugTools.hostAPI("push.remove", org.json.JSONObject().put("id", id).toString())
        assertTrue("Removing by the id failed: $removed", org.json.JSONObject(removed).optBoolean("ok"))
        assertTrue("The notification is still in the history", !AndroidDebugTools.pushStateJSON().contains(id))
    }

    @Test
    fun okHttpJsonWithAByteOrderMarkIsMasked() {
        val marker = java.util.UUID.randomUUID().toString().take(8)
        val json = "\uFEFF{\"password\":\"bom-secret-$marker\",\"note\":\"kept-$marker\"}"
        val client = okhttp3.OkHttpClient.Builder()
            .addInterceptor(debug.swift.android.DebugSwiftOkHttpInterceptor())
            // Answers in place of a server, so the test needs no network.
            .addInterceptor { chain ->
                okhttp3.Response.Builder()
                    .request(chain.request())
                    .protocol(okhttp3.Protocol.HTTP_1_1)
                    .code(200)
                    .message("OK")
                    .body(json.toByteArray(Charsets.UTF_8).toResponseBody("application/json; charset=utf-8".toMediaType()))
                    .build()
            }
            .build()
        client.newCall(okhttp3.Request.Builder().url("https://api.example.test/bom-$marker").build()).execute().close()

        val live = AndroidDebugTools.networkInspectorSnapshotJSON("http")
        assertTrue("This run's request is missing from the inspector", live.contains("bom-$marker"))
        assertTrue("The body lost its other fields", live.contains("kept-$marker"))
        assertTrue("A BOM-prefixed JSON body kept its password: $live", !live.contains("bom-secret-$marker"))
    }

    @Test
    fun pushStateComesBackExactlyAfterAReload() {
        fun state() = org.json.JSONObject(AndroidDebugTools.pushStateJSON())
        val preferences = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
            .getSharedPreferences("DebugSwift.PushNotifications", android.content.Context.MODE_PRIVATE)
        fun savedHistoryCount() = org.json.JSONArray(preferences.getString("history", "[]") ?: "[]").length()
        val originalHistory = preferences.getString("history", "[]")
        val configured = AndroidDebugTools.hostAPI("push.config", org.json.JSONObject()
            .put("interactionDelay", 2.7).put("maxHistoryCount", 1_500).toString())
        try {
            assertTrue("Configuring failed: $configured", org.json.JSONObject(configured).optBoolean("ok"))
            // More history than the old 1000-record cap on load, saved as the app saves it.
            val history = org.json.JSONArray()
            for (index in 0 until 1_200) {
                history.put(org.json.JSONObject().put("id", "restart-$index").put("title", "Restart $index")
                    .put("body", "Kept").put("status", "Delivered").put("trigger", "Immediate"))
            }
            preferences.edit().putString("history", history.toString()).commit()

            // Load the push state again from what was saved, through the launch path (PushRestartTest restarts the process).
            AndroidDebugTools.hostAPI("push.reloadState", "{}")
            assertTrue("The delay changed: ${state().optDouble("interactionDelay")}", state().optDouble("interactionDelay") == 2.7)
            assertTrue("The history limit changed: ${state().optInt("maxHistory")}", state().optInt("maxHistory") == 1_500)
            assertTrue("History was cut on load: ${savedHistoryCount()} of 1200 saved", savedHistoryCount() == 1_200)
        } finally {
            AndroidDebugTools.hostAPI("push.config", org.json.JSONObject()
                .put("interactionDelay", 3).put("maxHistoryCount", 100).toString())
            preferences.edit().putString("history", originalHistory).commit()
            AndroidDebugTools.hostAPI("push.reloadState", "{}")
        }
    }

    @Test
    fun savedHistoryIsMaskedWhenItLoads() {
        // A history file as an older version wrote it: a decrypted body with an encoded key, unmasked.
        val marker = java.util.UUID.randomUUID().toString().take(8)
        val history = java.io.File(
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.filesDir,
            "debugswift-network-history.json"
        )
        val row = org.json.JSONObject()
            .put("id", "legacy-$marker").put("sessionID", "legacy-session")
            .put("timestamp", System.currentTimeMillis()).put("method", "GET")
            .put("url", "https://api.example.test/legacy-$marker").put("status", 200)
            .put("durationMs", 5).put("requestBytes", 0).put("responseBytes", 10)
            .put("requestHeaders", org.json.JSONObject())
            .put("responseHeaders", org.json.JSONObject().put("Content-Type", "application/json"))
            .put("requestBody", "").put("responseBody", "{}")
            .put("decryptedResponseBody", "pass%77ord=legacy-secret-$marker&note=kept-$marker")
            .put("error", "").put("graphqlOperation", "").put("source", "http")
        history.writeText(org.json.JSONObject().put("requests", org.json.JSONArray().put(row)).toString())

        val reloaded = AndroidDebugTools.hostAPI("network.history.reload", "{}")
        assertTrue("Reloading failed: $reloaded", org.json.JSONObject(reloaded).optBoolean("ok"))
        val loaded = AndroidDebugTools.networkInspectorSnapshotJSON("network_history")
        assertTrue("The saved request did not load", loaded.contains("legacy-$marker"))
        assertTrue("The loaded body lost its other fields", loaded.contains("kept-$marker"))
        assertTrue("The loaded record kept the password: $loaded", !loaded.contains("legacy-secret-$marker"))

        // Loading rewrites the file, masked.
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline && history.readText().contains("legacy-secret-$marker")) {
            Thread.sleep(200)
        }
        assertTrue("The rewritten history file kept the password", !history.readText().contains("legacy-secret-$marker"))
    }

    @Test
    fun aSwiftDelayLandsAfterANativeWriteMadeBetweenItsReadAndItsPatch() {
        fun delay(enabled: Boolean, seconds: Double) = org.json.JSONObject(AndroidDebugTools.networkInjectionSettingsJSON())
            .also { it.put("delay", it.getJSONObject("delay").put("isEnabled", enabled).put("fixedDelay", seconds)) }
            .toString()
        val original = AndroidDebugTools.networkInjectionSettingsJSON()
        val nativeWrites = java.util.concurrent.atomic.AtomicInteger()
        try {
            // Swift reads an enabled 1 s delay; a native writer then disables it at 2 s before
            // Swift's enableRequestDelay(3) patches. The call must land after that write.
            AndroidDebugTools.applyNetworkInjectionSettingsJSON(delay(enabled = true, seconds = 1.0))
            AndroidDebugTools.afterInjectionRead.set {
                AndroidDebugTools.applyNetworkInjectionSettingsJSON(delay(enabled = false, seconds = 2.0))
                nativeWrites.incrementAndGet()
            }
            open("App", "Custom Actions")
            val action = hasText("Delay Requests by 3 Seconds") and hasClickAction()
            scrollTo(action)
            tap(action)
            waitFor(hasText("Action 'Delay Requests by 3 Seconds' completed.", substring = true))

            val settings = org.json.JSONObject(AndroidDebugTools.networkInjectionSettingsJSON()).getJSONObject("delay")
            assertTrue("The native write did not run between the read and the patch", nativeWrites.get() == 1)
            assertTrue("The delay is off after enableRequestDelay(3): $settings", settings.getBoolean("isEnabled"))
            assertTrue("The delay is not 3 s: $settings", settings.optDouble("fixedDelay") == 3.0)
        } finally {
            AndroidDebugTools.afterInjectionRead.set(null)
            AndroidDebugTools.applyNetworkInjectionSettingsJSON(original)
        }
    }

    @Test
    fun injectionChangesKeepRulesWrittenMeanwhile() {
        fun rules(pattern: String) = org.json.JSONObject()
            .put("delay", org.json.JSONObject().put("isEnabled", false))
            .put("failure", org.json.JSONObject().put("isEnabled", false))
            .put("rewrite", org.json.JSONObject().put("isEnabled", true).put("rules", org.json.JSONArray().put(
                org.json.JSONObject().put("id", pattern).put("urlPattern", pattern).put("responseBody", "{}")
                    .put("responseStatusCode", org.json.JSONObject.NULL).put("httpMethod", org.json.JSONObject.NULL)
                    .put("isEnabled", true).put("matchType", "wildcard"))))
            .toString()
        val original = AndroidDebugTools.networkInjectionSettingsJSON()
        try {
            // Swift read rules A, an import then replaced them with rules B, and Swift's
            // disableResponseBodyRewrite() arrives with only the field it changed.
            AndroidDebugTools.applyNetworkInjectionSettingsJSON(rules("https://a.test/*"))
            AndroidDebugTools.applyNetworkInjectionSettingsJSON(rules("https://b.test/*"))
            val patched = AndroidDebugTools.hostAPI("network.injection.patch", org.json.JSONObject()
                .put("sections", org.json.JSONObject().put("rewrite", org.json.JSONObject().put("isEnabled", false))).toString())
            assertTrue("The patch failed: $patched", org.json.JSONObject(patched).optBoolean("ok"))

            val rewrite = org.json.JSONObject(AndroidDebugTools.networkInjectionSettingsJSON()).getJSONObject("rewrite")
            assertTrue("The rewrite is still on", !rewrite.getBoolean("isEnabled"))
            val patterns = rewrite.getJSONArray("rules").toString()
            assertTrue("The imported rules were lost: $patterns", patterns.contains("b.test"))
            assertTrue("The older rules came back: $patterns", !patterns.contains("a.test"))
        } finally {
            AndroidDebugTools.applyNetworkInjectionSettingsJSON(original)
        }
    }

    @Test
    fun crashReportsShowAnUncaughtException() {
        // Reports from earlier runs are restored at launch, so this run's probe carries its own marker.
        val marker = java.util.UUID.randomUUID().toString().take(8)
        val thread = Thread({ throw CrashProbe("instrumented crash probe $marker") }, "debugswift-crash-probe-$marker")
        thread.start()
        thread.join(5_000)

        val newest = AndroidDebugTools.crashReportsNewestFirst().firstOrNull().orEmpty()
        assertTrue("The crash handler did not save this run's probe: $newest", newest.contains("instrumented crash probe $marker"))

        open("App", "Crash Reports")
        // Each report is listed by its first line: the time and the thread that crashed.
        waitFor(hasText("debugswift-crash-probe-$marker", substring = true))
    }

    /** Opens the debug panel from the button at the top of the demo list. */
    private fun openPanel() {
        tap(hasText("Open debug panel") and hasClickAction())
    }

    /** Opens the panel, then one area's list, then one feature in it. */
    private fun open(area: String, feature: String) {
        openPanel()
        val areaRow = hasText(area) and hasClickAction()
        scrollTo(areaRow)
        navigate(areaRow)
        val featureRow = hasText(feature) and hasClickAction()
        scrollTo(featureRow)
        navigate(featureRow)
    }

    /**
     * Taps a row that pushes a screen, until that row is gone. A tap that lands while the previous
     * push is still animating is dropped, so one tap is not enough. The row is tracked by its node
     * id: the pushed screen's top bar shows the same title and is clickable too.
     */
    private fun navigate(row: SemanticsMatcher) {
        repeat(5) {
            waitFor(row)
            val id = compose.onAllNodes(row).fetchSemanticsNodes().first().id
            val tapped = SemanticsMatcher("node #$id") { it.id == id }
            runCatching { compose.onNode(tapped).performClick() }
            compose.waitForIdle()
            val left = runCatching {
                compose.waitUntil(3_000) { compose.onAllNodes(tapped).fetchSemanticsNodes().isEmpty() }
            }.isSuccess
            if (left) return
        }
        throw AssertionError("Tapping ${row.description} did not open its screen")
    }

    /**
     * Lists are lazy: rows below the fold are not composed until scrolled to. The demo list stays
     * composed under the panel's sheet, so each scrollable list is tried until one holds the row.
     */
    private fun scrollTo(matcher: SemanticsMatcher, timeoutMs: Long = 20_000) {
        compose.waitUntil(timeoutMs) {
            if (compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty()) return@waitUntil true
            val lists = compose.onAllNodes(hasScrollToNodeAction())
            for (index in lists.fetchSemanticsNodes().indices) {
                try {
                    lists[index].performScrollToNode(matcher)
                    return@waitUntil true
                } catch (error: AssertionError) {
                    // Not in this list; try the next one.
                }
            }
            false
        }
    }

    private fun tap(matcher: SemanticsMatcher) {
        waitFor(matcher)
        compose.onAllNodes(matcher)[0].performClick()
        compose.waitForIdle()
    }

    private fun waitFor(matcher: SemanticsMatcher, timeoutMs: Long = 20_000) {
        try {
            compose.waitUntil(timeoutMs) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
        } catch (error: Throwable) {
            val roots = compose.onAllNodes(isRoot())
            for (index in roots.fetchSemanticsNodes().indices) {
                roots[index].printToLog("DebugSwiftPanelTest", maxDepth = Int.MAX_VALUE)
            }
            throw error
        }
    }

    private fun assertNoNode(matcher: SemanticsMatcher) {
        val count = compose.onAllNodes(matcher).fetchSemanticsNodes().size
        assertTrue("Expected no node matching ${matcher.description}, found $count", count == 0)
    }
}
