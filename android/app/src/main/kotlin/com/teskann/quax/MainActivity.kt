package com.teskann.quax

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.lang.ref.WeakReference

/**
 * A thin shell over the app-wide engine in [QuaxApplication]: closing the task
 * no longer destroys the Dart side, so the download worker (kept alive by the
 * foreground service) survives a swipe-away, and reopening re-attaches to the
 * same state.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as QuaxApplication).engine

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Plugins were registered when the Application created the cached
        // engine; re-registering here would add duplicates.
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        QuaxApplication.currentActivity = WeakReference(this)

        // Android 13+ wants the runtime permission for the progress bar; ask
        // here, where a real Activity exists.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4711)
        }
    }

    override fun onPause() {
        // The recents snapshot is taken right after the pause, so the window is
        // secured here rather than waiting for the Dart round trip. Dart clears
        // the flag again on resume (unless screenshots are disabled).
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onPause()
    }

    override fun onDestroy() {
        if (QuaxApplication.currentActivity?.get() === this) {
            QuaxApplication.currentActivity = null
        }
        super.onDestroy()
    }
}
