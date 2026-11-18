package debug.swift.android.sample

import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import debug.swift.android.AndroidDebugTools
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Drives the sample's debug panel on a device: the Swift UI rendered through Skip Fuse, the
 * Kotlin runtime that Application.onCreate installs, and the bridge between them.
 */
@RunWith(AndroidJUnit4::class)
class DebugSwiftPanelTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun panelListsTheAreasAndNetworkTools() {
        for (area in listOf("Network", "Performance", "Interface", "Resources", "App")) {
            waitFor(hasText(area) and hasClickAction())
        }
        waitFor(hasText("HTTP Inspector"))
    }

    @Test
    fun consoleShowsTheMessageLoggedFromSwift() {
        // DebugSwiftAndroidSampleAppDelegate.onLaunch logs this through DebugSwiftAndroidRuntime.
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
        val thread = Thread({ throw CrashProbe("instrumented crash probe") }, "debugswift-crash-probe")
        thread.start()
        thread.join(5_000)

        val newest = AndroidDebugTools.crashReportsNewestFirst().firstOrNull().orEmpty()
        assertTrue("The crash handler did not save the probe: $newest", newest.contains("instrumented crash probe"))

        open("App", "Crash Reports")
        // Each report is listed by its first line: the time and the thread that crashed.
        waitFor(hasText("debugswift-crash-probe", substring = true))
    }

    private fun open(area: String, feature: String) {
        // The area chips sit in a horizontal scroll view wider than a phone screen.
        val chip = hasText(area) and hasClickAction()
        waitFor(chip)
        compose.onAllNodes(chip)[0].performScrollTo()
        tap(chip)
        // The feature list is lazy: rows below the fold are not composed until scrolled to.
        val row = hasText(feature) and hasClickAction()
        waitFor(hasScrollToNodeAction())
        compose.onAllNodes(hasScrollToNodeAction())[0].performScrollToNode(row)
        tap(row)
    }

    private fun tap(matcher: SemanticsMatcher) {
        waitFor(matcher)
        compose.onAllNodes(matcher)[0].performClick()
        compose.waitForIdle()
    }

    private fun waitFor(matcher: SemanticsMatcher, timeoutMs: Long = 20_000) {
        compose.waitUntil(timeoutMs) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun assertNoNode(matcher: SemanticsMatcher) {
        val count = compose.onAllNodes(matcher).fetchSemanticsNodes().size
        assertTrue("Expected no node matching ${matcher.description}, found $count", count == 0)
    }
}
