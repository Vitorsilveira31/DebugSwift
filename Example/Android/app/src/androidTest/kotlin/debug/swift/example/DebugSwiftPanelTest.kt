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
