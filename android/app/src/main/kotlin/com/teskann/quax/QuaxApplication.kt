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
     * Showing deletes the `.nomedia` marker and rescans every media file,
     * answering only once the scanner called back for all of them. Hiding
     * writes the marker (which keeps future scans out) and deletes the files'
     * rows from the media database on every shared-storage volume, so SD-card
     * files disappear too; a second pass sweeps rows the provider re-created
     * mid-operation, and whatever stays behind (rows the app no longer owns)
     * is reported in `remaining`.
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

        if (visible) {
            File(dir, ".nomedia").delete()
            if (media.isEmpty()) {
                result.success(mapOf("affected" to 0, "remaining" to 0))
                return
            }

            var completed = 0
            var scanned = 0
            MediaScannerConnection.scanFile(this, media.toTypedArray(), null) { _, uri ->
                completed++
                if (uri != null) scanned++
                if (completed == media.size) {
                    mainHandler.post {
                        result.success(mapOf("affected" to scanned, "remaining" to 0))
                    }
                }
            }
            return
        }

        val nomedia = File(dir, ".nomedia")
        try {
            if (!nomedia.exists()) nomedia.createNewFile()
        } catch (e: IOException) {
            result.error("VISIBILITY_FAILED", e.message, null)
            return
        }

        // Deleting a MediaStore row deletes the file it points at, which used
        // to wipe downloaded videos when the switch was turned off. The marker
        // is the hiding mechanism: scanning it makes MediaProvider re-read the
        // folder rule and drop the entries. Rows that survive are only
        // counted, never deleted, so the UI can say the gallery may still list
        // them until it rescans.
        MediaScannerConnection.scanFile(this, arrayOf(nomedia.absolutePath), null) { _, _ ->
            mainHandler.post {
                result.success(mapOf("affected" to media.size, "remaining" to countMediaStoreRows(media)))
            }
        }
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

    private fun countMediaStoreRows(paths: List<String>): Int {
        var remaining = 0
        for (volume in externalVolumeNames()) {
            val collection = MediaStore.Files.getContentUri(volume)
            for (path in paths) {
                try {
                    contentResolver.query(
                        collection, arrayOf(MediaStore.MediaColumns._ID),
                        MediaStore.MediaColumns.DATA + " = ?", arrayOf(path), null
                    )?.use { remaining += it.count }
                } catch (e: Exception) {
                    // An unreadable volume simply cannot report leftovers.
                }
            }
        }
        return remaining
    }

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
