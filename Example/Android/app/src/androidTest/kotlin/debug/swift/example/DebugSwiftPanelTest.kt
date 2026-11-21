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
    fun pushStateComesBackExactlyAfterARestart() {
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

            // Load the push state again from what was saved, as a restart does.
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
