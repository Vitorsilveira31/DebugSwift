package debug.swift.example

import android.app.Activity
import android.os.Bundle
import android.widget.FrameLayout

/** A second, empty Activity for the instrumented tests, which need to switch Activities. Debug builds only. */
class SecondTestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(FrameLayout(this))
    }
}
