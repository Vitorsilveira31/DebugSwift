package debug.swift.example

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import debug.swift.android.AndroidDebugTools
import debug.swift.android.pushStateJSON
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The push options and history come back after the app process restarts. It runs in two stages,
 * each its own `am instrument` (which starts a fresh app process), with `am force-stop` between
 * them: run-instrumented-tests.sh passes `-e pushRestartStage save`, then `-e pushRestartStage check`.
 * Without that argument, as in the main run, both tests are skipped.
 */
@RunWith(AndroidJUnit4::class)
class PushRestartTest {
    private val stage = InstrumentationRegistry.getArguments().getString("pushRestartStage")
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val preferences = context.getSharedPreferences("DebugSwift.PushNotifications", android.content.Context.MODE_PRIVATE)
    /** Holds the history the device had before the test, so the check stage can put it back. */
    private val stash = context.getSharedPreferences("DebugSwift.PushRestartTest", android.content.Context.MODE_PRIVATE)

    @Test
    fun savesPushState() {
        assumeTrue(stage == "save")
        stash.edit().putString("history", preferences.getString("history", "[]")).commit()
        val configured = AndroidDebugTools.hostAPI("push.config", JSONObject()
            .put("interactionDelay", 2.7).put("maxHistoryCount", 1_500).toString())
        assertTrue("Configuring failed: $configured", JSONObject(configured).optBoolean("ok"))
        // More history than the old 1000-record cap on load, saved as the app saves it.
        val history = JSONArray()
        for (index in 0 until RECORDS) {
            history.put(JSONObject().put("id", "restart-$index").put("title", "Restart $index")
                .put("body", "Kept").put("status", "Delivered").put("trigger", "Immediate"))
        }
        assertTrue("Saving the history failed", preferences.edit().putString("history", history.toString()).commit())
    }

    @Test
    fun readsPushStateAfterARestart() {
        assumeTrue(stage == "check")
        try {
            // A new process: Application.onCreate loaded the push state from storage.
            val state = JSONObject(AndroidDebugTools.pushStateJSON())
            val saved = JSONArray(preferences.getString("history", "[]") ?: "[]")
            assertTrue("The delay changed: ${state.optDouble("interactionDelay")}", state.optDouble("interactionDelay") == 2.7)
            assertTrue("The history limit changed: ${state.optInt("maxHistory")}", state.optInt("maxHistory") == 1_500)
            assertTrue("History was cut on load: ${saved.length()} of $RECORDS saved", saved.length() == RECORDS)
            assertTrue("The records changed", saved.getJSONObject(RECORDS - 1).optString("id") == "restart-${RECORDS - 1}")
        } finally {
            AndroidDebugTools.hostAPI("push.config", JSONObject()
                .put("interactionDelay", 3).put("maxHistoryCount", 100).toString())
            preferences.edit().putString("history", stash.getString("history", "[]")).commit()
            stash.edit().clear().commit()
            AndroidDebugTools.hostAPI("push.reloadState", "{}")
        }
    }

    private companion object {
        const val RECORDS = 1_200
    }
}
