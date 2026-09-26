package com.teskann.quax

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.content.FileProvider
import androidx.multidex.MultiDex
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.lang.ref.WeakReference

/**
 * Hosts the app-wide FlutterEngine instead of the Activity: swiping the app
 * away destroys the Activity but not the Dart isolate, so a running download
 * (kept alive by the foreground service) continues. Reopening the app attaches
 * a fresh Activity onto the same engine, state intact.
 *
 * The `browser_resolver` channel lives here too, so the foreground service can
 * reach Dart even while no Activity is attached.
 */
class QuaxApplication : android.app.Application() {
    companion object {
        // The foreground service reaches Dart through this when a notification
        // action is tapped.
        @JvmStatic
        var channel: MethodChannel? = null

        // Activity-aware calls (permission requests) need the current Activity;
        // everything else works off the application context.
        @JvmStatic
        var currentActivity: WeakReference<Activity>? = null

        // A gallery pass must always answer, even when the system scanner stays
        // silent (an OEM provider with its own index, a headless emulator).
        private const val SCAN_TIMEOUT_MS = 10_000L

        // MediaScannerConnection is fire-and-forget with no progress: handing it
        // thousands of paths at once makes MediaProvider queue them all before
        // it indexes anything, and the switch sat blind for the whole wait. The
        // pass now walks the list in batches and reports each one, and the
        // short breather between batches lets the provider flush — a large
        // hidden pass also finishes sooner than it did in one lump.
        private const val SCAN_BATCH = 40
        private const val SCAN_BATCH_GAP_MS = 25L

        private const val TAG = "QuaX"
    }

    lateinit var engine: FlutterEngine
        private set

    // Scan callbacks arrive on a binder thread; MethodChannel results belong to
    // the main one.
    private val mainHandler = Handler(Looper.getMainLooper())

    private val mediaExtensions = setOf(
        "mp4", "mov", "webm", "mkv", "m4v", "avi", "ts", "3gp", "mpeg", "mpg", "wmv", "flv", "m2ts", "ogv",
        "jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif", "tiff"
    )

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        MultiDex.install(this)
    }

    override fun onCreate() {
        super.onCreate()

        engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "browser_resolver")
            .also { it.setMethodCallHandler(::onMethodCall) }
    }

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    /**
     * Shows or hides the library folder's media from gallery apps, and reports
     * how many files were affected so the UI can confirm the outcome instead of
     * guessing.
     *
     * The files themselves are never touched. MediaProvider decides what the
     * gallery lists, so the pass works on it: hiding writes the `.nomedia`
     * marker and then rescans every media file — the rescan is what makes the
     * provider re-read the folder rule and drop them from the media collections
     * (they stay reachable as plain files). Scanning only the marker is not
     * enough on MIUI, where rows indexed before survive it; that was why the
     * switch looked broken. Showing deletes the marker and rescans the files,
     * which puts them back.
     *
     * Whatever the provider still lists as media after both passes is counted,
     * never deleted — deleting a MediaStore row deletes the file it points at —
     * and reported as `remaining`. Answers at most [SCAN_TIMEOUT_MS] per pass,
     * so the switch can never hang.
     */
    private fun setGalleryVisibility(dirPath: String, visible: Boolean, result: MethodChannel.Result) {
        val dir = File(dirPath)
        if (!dir.exists()) {
            result.error("INVALID_ARGUMENT", "Directory does not exist", null)
            return
        }

        val media = try {
            mediaFilesUnder(dir)
        } catch (e: Exception) {
            emptyList()
        }
        val nomedia = File(dir, ".nomedia")

        if (visible) {
            try {
                if (nomedia.exists()) nomedia.delete()
            } catch (e: IOException) {
                result.error("VISIBILITY_FAILED", e.message, null)
                return
            }

            if (media.isEmpty()) {
                result.success(mapOf("affected" to 0, "remaining" to 0))
                return
            }

            scanPaths(media, onProgress = { done, total ->
                emitProgress(done, total, "scan")
            }) {
                val indexed = visibleMediaUnder(dir).size
                Log.i(TAG, "gallery show: ${media.size} files, $indexed in the gallery")
                result.success(mapOf("affected" to indexed, "remaining" to (media.size - indexed).coerceAtLeast(0)))
            }
            return
        }

        try {
            if (!nomedia.exists()) nomedia.createNewFile()
        } catch (e: IOException) {
            result.error("VISIBILITY_FAILED", e.message, null)
            return
        }

        if (media.isEmpty()) {
            result.success(mapOf("affected" to 0, "remaining" to 0))
            return
        }

        // The marker goes through the scanner as well: on stock Android its scan
        // is what removes rows for the whole folder, the per-file scans cover
        // the providers that ignore it.
        scanPaths(media + nomedia.absolutePath, onProgress = { done, total ->
            emitProgress(done, total, "scan")
        }) {
            hideLeftovers(dir, media, result)
        }
    }

    /** Streams a pass' progress to Dart, which owns the switch's progress bar. */
    private fun emitProgress(done: Int, total: Int, phase: String) {
        mainHandler.post {
            try {
                channel?.invokeMethod("galleryProgress", mapOf("done" to done, "total" to total, "phase" to phase))
            } catch (e: Exception) {
                // No engine attached: progress is cosmetic, never fatal.
            }
        }
    }

    /**
     * Second chance for the providers that answer the first rescan from a cache:
     * whatever is still listed in the gallery is scanned once more, then the
     * outcome is reported.
     */
    private fun hideLeftovers(dir: File, media: List<String>, result: MethodChannel.Result) {
        val left = visibleMediaUnder(dir)
        if (left.isEmpty()) {
            Log.i(TAG, "gallery hide: all ${media.size} files left the gallery")
            result.success(mapOf("affected" to media.size, "remaining" to 0))
            return
        }

        scanPaths(left, onProgress = { done, total ->
            emitProgress(done, total, "verify")
        }) {
            val remaining = visibleMediaUnder(dir).size
            Log.i(TAG, "gallery hide: ${media.size - remaining} of ${media.size} left the gallery, $remaining still visible")
            result.success(
                mapOf("affected" to (media.size - remaining).coerceAtLeast(0), "remaining" to remaining)
            )
        }
    }

    /**
     * Runs [paths] through the system media scanner and calls [done] once every
     * path was reported — or when [SCAN_TIMEOUT_MS] passes without any new
     * callback, so a scanner that stays silent cannot leave the switch spinning
     * forever.
     *
     * Paths go out in [SCAN_BATCH]-sized chunks with [onProgress] reporting the
     * running count, which is what lets the Dart switch show a real bar instead
     * of a blind spinner; the caller labels the phase it belongs to.
     */
    private fun scanPaths(
        paths: List<String>,
        onProgress: (done: Int, total: Int) -> Unit = { _, _ -> },
        done: () -> Unit,
    ) {
        if (paths.isEmpty()) {
            mainHandler.post(done)
            return
        }

        val total = paths.size
        var finished = false
        var next = 0
        val scanned = java.util.Collections.synchronizedSet(mutableSetOf<String>())

        fun finish() {
            if (finished) return
            finished = true
            done()
        }

        // Inactivity timeout, not a budget for the whole walk: every batch we
        // hand over pushes it back, so a slow-but-alive provider is never cut
        // off while a silent one still answers within SCAN_TIMEOUT_MS.
        val timeout = Runnable { finish() }

        fun pump() {
            if (finished) return
            if (next >= total) {
                // Every batch was handed over; a provider may still owe us the
                // last callbacks, so let the timeout collect them.
                mainHandler.postDelayed(timeout, SCAN_TIMEOUT_MS)
                return
            }

            val end = minOf(next + SCAN_BATCH, total)
            val batch = paths.subList(next, end).toTypedArray()
            next = end

            mainHandler.removeCallbacks(timeout)
            mainHandler.postDelayed(timeout, SCAN_TIMEOUT_MS)

            MediaScannerConnection.scanFile(this, batch, null) { path, _ ->
                if (path != null) scanned.add(path)
                if (scanned.size >= total) finish()
            }
            onProgress(next, total)
            mainHandler.postDelayed({ pump() }, SCAN_BATCH_GAP_MS)
        }

        pump()
    }

    private fun mediaFilesUnder(dir: File): List<String> =
        dir.walkTopDown()
            .filter { it.isFile && it.extension.lowercase() in mediaExtensions }
            .map { it.absolutePath }
            .toList()

    /** Shared-storage volumes the media database knows about (SD cards included). */
    private fun externalVolumeNames(): List<String> {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.getExternalVolumeNames(this).toList()
            } else {
                listOf("external")
            }
        } catch (e: Exception) {
            listOf("external")
        }
    }

    /**
     * The folder's media as the gallery sees it: rows of the media collections,
     * so the plain file rows MIUI leaves behind while hidden do not count as
     * leftovers.
     */
    private fun visibleMediaUnder(dir: File): List<String> {
        val selection = "${MediaStore.Files.FileColumns.DATA} LIKE ? ESCAPE '\\' AND " +
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} != ${MediaStore.Files.FileColumns.MEDIA_TYPE_NONE}"
        val args = arrayOf("${escapeLike(dir.absolutePath)}/%")
        val paths = mutableListOf<String>()

        for (volume in externalVolumeNames()) {
            try {
                contentResolver.query(
                    MediaStore.Files.getContentUri(volume),
                    arrayOf(MediaStore.Files.FileColumns.DATA),
                    selection,
                    args,
                    null
                )?.use { cursor ->
                    while (cursor.moveToNext()) {
                        cursor.getString(0)?.let { paths.add(it) }
                    }
                }
            } catch (e: Exception) {
                // An unreadable volume simply cannot report what it lists.
            }
        }
        return paths
    }

    private fun escapeLike(value: String): String =
        value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "downloadNotification") {
            val intent = Intent(this, DownloadForegroundService::class.java).apply {
                putExtra(DownloadForegroundService.EXTRA_TITLE, call.argument<String>("title"))
                putExtra(DownloadForegroundService.EXTRA_BODY, call.argument<String>("body"))
                putExtra(DownloadForegroundService.EXTRA_PERCENT, call.argument<Int>("percent") ?: 0)
                putExtra(DownloadForegroundService.EXTRA_FILE, call.argument<String>("fileName"))
                putExtra(DownloadForegroundService.EXTRA_PAUSE_LABEL, call.argument<String>("pauseLabel"))
                putExtra(DownloadForegroundService.EXTRA_CANCEL_LABEL, call.argument<String>("cancelLabel"))
            }
            DownloadForegroundService.start(this, intent)
            result.success(true)
        } else if (call.method == "stopDownloadNotification") {
            DownloadForegroundService.stop(this)
            result.success(true)
        } else if (call.method == "requestNotificationsPermission") {
            val activity = currentActivity?.get()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && activity != null &&
                activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                activity.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 4711)
            }
            result.success(true)
        } else if (call.method == "setRecentsSecure") {
            val secure = call.argument<Boolean>("secure") ?: false
            val activity = currentActivity?.get()
            activity?.runOnUiThread {
                if (secure) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
            }
            result.success(true)
        } else if (call.method == "getDefaultBrowser") {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                data = Uri.parse("https://")
            }
            val resolveInfo = packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
            if (resolveInfo != null) {
                result.success(resolveInfo.activityInfo.packageName)
            } else {
                result.success(null)
            }
        } else if (call.method == "hasAllFilesAccess") {
            result.success(hasAllFilesAccess())
        } else if (call.method == "requestAllFilesAccess") {
            if (hasAllFilesAccess()) {
                result.success(true)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:$packageName")
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(false)
                } catch (e: Exception) {
                    val fallback = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(fallback)
                    result.success(false)
                }
            } else {
                result.success(true) // pre-R: manifest runtime permission governs this
            }
        } else if (call.method == "setGalleryVisibility") {
            val dirPath = call.argument<String>("path")
            val visible = call.argument<Boolean>("visible")
            if (dirPath != null && visible != null) {
                setGalleryVisibility(dirPath, visible, result)
            } else {
                result.error("INVALID_ARGUMENT", "path or visible is null", null)
            }
        } else if (call.method == "isMetered") {
            try {
                val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                result.success(manager.isActiveNetworkMetered)
            } catch (e: Exception) {
                result.success(false)
            }
        } else if (call.method == "getAvailableSpace") {
            val path = call.argument<String>("path")
            if (path == null) {
                result.error("INVALID_ARGUMENT", "path is null", null)
            } else {
                try {
                    var probe = File(path)
                    while (!probe.exists() && probe.parentFile != null) {
                        probe = probe.parentFile!!
                    }
                    val stat = StatFs(probe.path)
                    result.success(stat.availableBytes)
                } catch (e: Exception) {
                    result.error("STAT_FAILED", e.message, null)
                }
            }
        } else if (call.method == "openMediaFile") {
            val path = call.argument<String>("path")
            val mime = call.argument<String>("mime") ?: "*/*"
            if (path == null) {
                result.error("INVALID_ARGUMENT", "path is null", null)
            } else {
                val file = File(path)
                if (!file.exists()) {
                    result.error("NOT_FOUND", "File does not exist", null)
                } else {
                    try {
                        val uri = FileProvider.getUriForFile(this, "$packageName.library", file)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mime)
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
                            )
                        }
                        startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", e.message, null)
                    }
                }
            }
        } else if (call.method == "videoThumbnail") {
            val videoPath = call.argument<String>("path")
            val outPath = call.argument<String>("outPath")
            if (videoPath != null && outPath != null) {
                var success: String? = null
                try {
                    val retriever = MediaMetadataRetriever()
                    retriever.setDataSource(videoPath)
                    val frame = retriever.getFrameAtTime(1_000_000L) // one second in
                    retriever.release()
                    if (frame != null) {
                        File(outPath).parentFile?.mkdirs()
                        FileOutputStream(outPath).use { stream ->
                            frame.compress(Bitmap.CompressFormat.JPEG, 70, stream)
                        }
                        frame.recycle()
                        success = outPath
                    }
                    result.success(success)
                } catch (e: IOException) {
                    result.error("THUMBNAIL_FAILED", e.message, null)
                } catch (e: RuntimeException) {
                    result.error("THUMBNAIL_FAILED", e.message, null)
                }
            } else {
                result.error("INVALID_ARGUMENT", "path is null", null)
            }
        }
    }
}
