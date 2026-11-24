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
import android.system.Os
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.UUID
import java.util.concurrent.RejectedExecutionException

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
        lateinit var instance: QuaxApplication
            private set

        @JvmStatic
        var channel: MethodChannel? = null

        // Activity-aware calls (permission requests) need the current Activity;
        // everything else works off the application context.
        @JvmStatic
        var currentActivity: WeakReference<Activity>? = null

        // Runtime storage request on Android 10 and below: the user's answer
        // arrives after the dialog, in Activity.onRequestPermissionsResult.
        private const val STORAGE_REQUEST_CODE = 4712
        private var pendingStoragePermission: MethodChannel.Result? = null

        // Kept in step with CrashLog.maxBytes: the same file, written from
        // both sides, rotated before it can grow without bound.
        private const val CRASH_LOG_MAX_BYTES = 256 * 1024L

        // The library grid decodes its own copy at tile width (max 1080 px), so
        // a larger frame is never displayed.
        private const val THUMBNAIL_MAX_SIDE = 1080

        private var downloadServiceReady = false
        private var pendingDownloadStart: MethodChannel.Result? = null

        private class PendingSave(val result: MethodChannel.Result, val source: File)
        private var pendingSave: PendingSave? = null
        private val saveExecutor = Executors.newSingleThreadExecutor()
        const val SAVE_MEDIA_REQUEST = 4720

        fun onDownloadServiceReady() {
            downloadServiceReady = true
            pendingDownloadStart?.success(true)
            pendingDownloadStart = null
            notifyDart("onDownloadServiceReady")
        }

        fun onDownloadServiceFailed() {
            downloadServiceReady = false
            pendingDownloadStart?.error("SERVICE_START_FAILED", "Foreground service did not start", null)
            pendingDownloadStart = null
            notifyDart("onDownloadServiceFailed")
        }

        fun onDownloadServiceDestroyed() {
            if (downloadServiceReady) {
                downloadServiceReady = false
                notifyDart("onDownloadServiceFailed")
            }
        }

        fun beginSaveMedia(sourcePath: String, fileName: String, result: MethodChannel.Result) {
            val activity = currentActivity?.get()
            if (activity == null) {
                result.error("NO_ACTIVITY", "No activity is available to choose a destination", null)
                return
            }
            val source = File(sourcePath)
            if (!source.isFile) {
                result.error("INVALID_ARGUMENT", "Source media does not exist", null)
                return
            }
            pendingSave?.result?.error("SAVE_SUPERSEDED", "A newer save replaced this one", null)
            pendingSave = PendingSave(result, source)
            val extension = fileName.substringAfterLast('.', "").lowercase()
            val mime = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "*/*"
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mime
                putExtra(Intent.EXTRA_TITLE, fileName)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
            try {
                activity.startActivityForResult(intent, SAVE_MEDIA_REQUEST)
            } catch (e: Exception) {
                pendingSave = null
                result.error("SAVE_FAILED", e.javaClass.simpleName, null)
            }
        }

        fun completeSaveMedia(resultCode: Int, data: Intent?) {
            val pending = pendingSave ?: return
            pendingSave = null
            val uri = data?.data
            if (resultCode != android.app.Activity.RESULT_OK || uri == null) {
                pending.result.success(null)
                return
            }
            val flags = data.flags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            if (flags != 0) {
                try {
                    instance.contentResolver.takePersistableUriPermission(uri, flags)
                } catch (_: SecurityException) {
                    // Some providers do not offer persistable grants; the current
                    // process can still use the returned URI.
                }
            }
            saveExecutor.execute {
                val failure = try {
                    val context = QuaxApplication.instance
                    context.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        val copied = pending.source.inputStream().use { input -> input.copyTo(output) }
                        if (copied != pending.source.length()) {
                            throw IOException("Saved length verification failed")
                        }
                        output.flush()
                    } ?: throw IOException("Content provider returned no output stream")
                    null
                } catch (e: Exception) {
                    try {
                        instance.contentResolver.openOutputStream(uri, "wt")?.use { }
                    } catch (_: Exception) {
                        // Best-effort removal of a partial provider write.
                    }
                    e.javaClass.simpleName
                }
                instance.mainHandler.post {
                    if (failure == null) pending.result.success(uri.toString())
                    else pending.result.error("SAVE_FAILED", failure, null)
                }
            }
        }

        fun cancelPendingSave() {
            val pending = pendingSave ?: return
            pendingSave = null
            pending.result.error("SAVE_CANCELLED", "Activity was destroyed", null)
        }

        private fun notifyDart(method: String) {
            try {
                channel?.invokeMethod(method, null)
            } catch (_: Exception) {
                // The engine can be detached; Dart's readiness timeout is the fallback.
            }
        }
    }

    lateinit var engine: FlutterEngine
        private set

    // Scan callbacks arrive on a binder thread; MethodChannel results belong to
    // the main one.
    private val mainHandler = Handler(Looper.getMainLooper())

    // One thumbnail worker for the whole process. A new executor per request
    // parked a core thread forever, so scrolling a large gallery leaked one
    // thread per clip until pthread_create failed.
    private val thumbnailExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        instance = this

        installCrashHandler()

        engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "browser_resolver")
            .also { it.setMethodCallHandler(::onMethodCall) }
    }

    /**
     * Native deaths — an OOM in the thumbnail decoder, an exception escaping a
     * channel handler — never reach Dart, so they used to leave nothing behind
     * but a logcat line. They are appended to the same crashes.log that
     * Settings shows, then the platform handler still runs.
     */
    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                appendCrashLog(thread, error)
            } catch (_: Throwable) {
                // Recording a crash must never become a second crash.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    private fun appendCrashLog(thread: Thread, error: Throwable) {
        val file = File(filesDir, "crashes.log")
        if (file.exists() && file.length() > CRASH_LOG_MAX_BYTES) {
            val backup = File(filesDir, "crashes.log.1")
            backup.delete()
            file.renameTo(backup)
        }
        val entry = buildString {
            append("--- ")
            append(java.util.Date().toString())
            append(" [native:")
            append(thread.name)
            append("]\n")
            append(error.toString())
            append('\n')
            append(android.util.Log.getStackTraceString(error))
            append('\n')
        }
        file.appendText(entry)
    }

    /**
     * One frame, downscaled so its long side is at most [THUMBNAIL_MAX_SIDE].
     *
     * `getFrameAtTime` decodes at the source resolution: a 4K frame is ~33 MB
     * of ARGB, and the gallery asks for one per video tile. The thumbnail is
     * written as a 70% JPEG at tile width, so those extra pixels were decoded
     * only to be thrown away — and the peak was what pushed a 4 GB phone into
     * the low-memory killer.
     */
    private fun decodeThumbnailFrame(retriever: MediaMetadataRetriever): Bitmap? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) {
            return retriever.getFrameAtTime(1_000_000L)
        }
        val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            ?.toIntOrNull() ?: 0
        val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            ?.toIntOrNull() ?: 0
        val longest = maxOf(width, height)
        if (longest <= THUMBNAIL_MAX_SIDE) {
            return retriever.getFrameAtTime(1_000_000L)
        }
        val scale = THUMBNAIL_MAX_SIDE.toFloat() / longest
        return retriever.getScaledFrameAtTime(
            1_000_000L,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            (width * scale).toInt().coerceAtLeast(1),
            (height * scale).toInt().coerceAtLeast(1)
        )
    }

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // Android 10 and below write through legacy storage, so the runtime
            // WRITE_EXTERNAL_STORAGE grant is what opens the library folder.
            checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    /** Answers the pending legacy-storage request from the Activity's permission callback. */
    fun onStoragePermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != STORAGE_REQUEST_CODE) return
        val result = pendingStoragePermission ?: return
        pendingStoragePermission = null
        result.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
    }

    /** Answers a pending storage request when its Activity goes away, so Dart never hangs. */
    fun cancelPendingStoragePermission() {
        val result = pendingStoragePermission ?: return
        pendingStoragePermission = null
        result.success(false)
    }

    /**
     * Shows or hides the library folder's media from gallery apps.
     *
     * The whole mechanism is the `.nomedia` marker: hiding creates it, showing
     * removes it, and one scan of the folder asks MediaProvider to refresh its
     * index. No MediaStore row is ever deleted — deleting a row deletes the
     * file it points at. The files themselves stay in place, so file managers
     * still list them while gallery apps that respect the marker (the system
     * gallery, MX Player) hide the folder.
     */
    private fun setGalleryVisibility(dirPath: String, visible: Boolean, result: MethodChannel.Result) {
        val dir = File(dirPath)
        if (!dir.isDirectory) {
            result.error("INVALID_ARGUMENT", "Directory does not exist", null)
            return
        }

        val nomedia = File(dir, ".nomedia")
        try {
            if (visible) {
                if (nomedia.exists()) nomedia.delete()
            } else if (!nomedia.exists()) {
                nomedia.createNewFile()
            }
        } catch (e: IOException) {
            result.error("VISIBILITY_FAILED", e.message, null)
            return
        }

        // One scan of the folder: MediaProvider indexes the files on show and
        // applies the marker on hide. Gallery apps that read the marker
        // themselves need nothing else.
        MediaScannerConnection.scanFile(this, arrayOf(dir.absolutePath), null, null)
        result.success(true)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            handleMethodCall(call, result)
        } catch (e: Exception) {
            // Flutter's messenger does not catch a handler exception: it lands
            // on the platform thread and kills the process. A revoked storage
            // grant (SecurityException) or a missing fallback activity used to
            // take the app down instead of failing one call.
            android.util.Log.w("QuaxChannel", "method ${call.method} failed", e)
            try {
                result.error("NATIVE_ERROR", e.message ?: e.javaClass.simpleName, null)
            } catch (_: Exception) {
                // The result may already have been answered.
            }
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "downloadNotification" || call.method == "startDownloadNotification") {
            val intent = Intent(this, DownloadForegroundService::class.java).apply {
                putExtra(DownloadForegroundService.EXTRA_TITLE, call.argument<String>("title"))
                putExtra(DownloadForegroundService.EXTRA_BODY, call.argument<String>("body"))
                putExtra(DownloadForegroundService.EXTRA_PERCENT, call.argument<Int>("percent") ?: 0)
                putExtra(DownloadForegroundService.EXTRA_FILE, call.argument<String>("fileName"))
                putExtra(DownloadForegroundService.EXTRA_ATTEMPT, call.argument<String>("attemptId"))
                putExtra(DownloadForegroundService.EXTRA_PAUSE_LABEL, call.argument<String>("pauseLabel"))
                putExtra(DownloadForegroundService.EXTRA_CANCEL_LABEL, call.argument<String>("cancelLabel"))
            }
            if (call.method == "downloadNotification") {
                DownloadForegroundService.start(this, intent)
                result.success(true)
            } else if (downloadServiceReady) {
                if (DownloadForegroundService.start(this, intent)) result.success(true)
                else result.error("SERVICE_START_FAILED", "Foreground service update failed", null)
            } else {
                pendingDownloadStart?.error("START_SUPERSEDED", "A newer start replaced this one", null)
                pendingDownloadStart = result
                DownloadForegroundService.start(this, intent)
            }
        } else if (call.method == "stopDownloadNotification") {
            downloadServiceReady = false
            pendingDownloadStart?.error("SERVICE_STOPPED", "Download service stopped", null)
            pendingDownloadStart = null
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
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val activity = currentActivity?.get()
                if (activity == null) {
                    result.success(false)
                } else {
                    // A second ask supersedes the first: answer the old call so
                    // its Dart future does not hang.
                    pendingStoragePermission?.success(false)
                    pendingStoragePermission = result
                    activity.requestPermissions(
                        arrayOf(
                            android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
                            android.Manifest.permission.READ_EXTERNAL_STORAGE
                        ),
                        STORAGE_REQUEST_CODE
                    )
                }
            } else {
                result.success(true) // pre-M: install-time grants
            }
        } else if (call.method == "enableWebViewPopups") {
            // "Sign in with Google" needs window.open; the plugin drops the
            // popup's opener, so the popup is hosted in a dialog instead.
            currentActivity?.get()?.let { WebViewPopups.install(it) }
            result.success(null)
        } else if (call.method == "openAppSettings") {
            // MIUI and other ROMs stop showing the dialog after two denials;
            // the app details screen is the only way left to grant storage.
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName")
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                result.success(true)
            } catch (e: Exception) {
                result.error("SETTINGS_FAILED", e.message, null)
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
        } else if (call.method == "isSameStorageVolume") {
            val first = call.argument<String>("path1")
            val second = call.argument<String>("path2")
            if (first == null || second == null) {
                result.error("INVALID_ARGUMENT", "path1 or path2 is null", null)
            } else {
                try {
                    fun existingProbe(path: String): File {
                        var probe = File(path)
                        while (!probe.exists() && probe.parentFile != null) probe = probe.parentFile!!
                        return probe
                    }
                    val same = Os.stat(existingProbe(first).path).st_dev ==
                        Os.stat(existingProbe(second).path).st_dev
                    result.success(same)
                } catch (e: Exception) {
                    result.error("STAT_FAILED", e.javaClass.simpleName, null)
                }
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
        } else if (call.method == "encryptSession" || call.method == "decryptSession") {
            val value = call.argument<String>("text")
            if (value == null) {
                result.error("INVALID_ARGUMENT", "session string is null", null)
            } else {
                try {
                    result.success(
                        if (call.method == "encryptSession") SessionCipher.encrypt(value)
                        else SessionCipher.decrypt(value)
                    )
                } catch (e: Exception) {
                    // Never include the session or envelope in an error detail.
                    result.error("KEYSTORE_FAILED", e.javaClass.simpleName, null)
                }
            }
        } else if (call.method == "scanMediaFile") {
            val path = call.argument<String>("path")
            if (path == null || !File(path).isFile) {
                result.error("INVALID_ARGUMENT", "Media file does not exist", null)
            } else {
                MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
                result.success(true)
            }
        } else if (call.method == "saveMediaFile") {
            val sourcePath = call.argument<String>("sourcePath")
            val fileName = call.argument<String>("fileName")
            if (sourcePath == null || fileName == null) {
                result.error("INVALID_ARGUMENT", "sourcePath or fileName is null", null)
            } else {
                beginSaveMedia(sourcePath, fileName, result)
            }
        } else if (call.method == "copyMediaUriToCache") {
            val uri = call.argument<String>("uri")
            val outPath = call.argument<String>("outPath")
            if (uri == null || outPath == null) {
                result.error("INVALID_ARGUMENT", "uri or outPath is null", null)
            } else {
                try {
                    saveExecutor.execute {
                        val output = File(outPath)
                        val failure = try {
                            output.parentFile?.mkdirs()
                            contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
                                FileOutputStream(output).use { sink -> input.copyTo(sink) }
                            } ?: throw IOException("Content provider returned no stream")
                            if (output.length() <= 0) throw IOException("Empty media copy")
                            null
                        } catch (e: Exception) {
                            output.delete()
                            e.javaClass.simpleName
                        }
                        mainHandler.post {
                            if (failure == null) result.success(output.absolutePath)
                            else result.error("URI_COPY_FAILED", failure, null)
                        }
                    }
                } catch (e: RejectedExecutionException) {
                    File(outPath).delete()
                    result.error("URI_COPY_BUSY", "Save worker is busy", null)
                }
            }
        } else if (call.method == "openMediaFile" || call.method == "openMediaLocation") {
            val path = call.argument<String>("path")
            val uri = call.argument<String>("uri")
            val mime = call.argument<String>("mime") ?: "*/*"
            if (path == null && uri == null) {
                result.error("INVALID_ARGUMENT", "path or uri is null", null)
            } else {
                try {
                    val mediaUri = if (uri != null) {
                        Uri.parse(uri)
                    } else {
                        val sourceFile = java.io.File(path!!)
                        if (!sourceFile.exists()) throw IOException("File does not exist")
                        FileProvider.getUriForFile(this@QuaxApplication, "$packageName.library", sourceFile)
                    }
                    val resolvedMime = if (mime == "*/*" && uri != null) {
                        contentResolver.getType(mediaUri) ?: mime
                    } else mime
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(mediaUri, resolvedMime)
                        addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
                        )
                    }
                    startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                } catch (e: Exception) {
                    result.error("OPEN_FAILED", e.javaClass.simpleName, null)
                }
            }
        } else if (call.method == "videoThumbnail") {
            val videoPath = call.argument<String>("path")
            val outPath = call.argument<String>("outPath")
            if (videoPath == null || outPath == null) {
                result.error("INVALID_ARGUMENT", "path is null", null)
                return
            }

            // Off the platform thread: setDataSource + getFrameAtTime is a seek
            // and a decode, and the gallery grid asks for one per video tile —
            // a dozen tiles meant a dozen main-thread decodes, which drops
            // frames and can ANR. MethodChannel results must be delivered on
            // the main thread, hence the post back.
            try {
                thumbnailExecutor.execute {
                    var success: String? = null
                    var failure: Pair<String, String?>? = null
                    var frame: Bitmap? = null
                    val destination = File(outPath)
                    val temp = File(
                        destination.parentFile,
                        "${destination.name}.${UUID.randomUUID()}.tmp"
                    )
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(videoPath)
                        val bitmap = decodeThumbnailFrame(retriever)
                        if (bitmap != null) {
                            frame = bitmap
                            destination.parentFile?.mkdirs()
                            FileOutputStream(temp.path).use { stream ->
                                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 70, stream)) {
                                    throw IOException("JPEG compression failed")
                                }
                            }
                            if (temp.length() <= 0) throw IOException("Empty thumbnail")
                            if (!temp.renameTo(destination)) {
                                throw IOException("Thumbnail promotion failed")
                            }
                            success = destination.path
                        }
                    } catch (e: IOException) {
                        failure = Pair("THUMBNAIL_FAILED", e.javaClass.simpleName)
                    } catch (e: RuntimeException) {
                        failure = Pair("THUMBNAIL_FAILED", e.javaClass.simpleName)
                    } catch (e: OutOfMemoryError) {
                        // An Error, not an Exception: it used to escape this worker
                        // and kill the process while the gallery was scrolling.
                        failure = Pair("THUMBNAIL_FAILED", "out of memory")
                    } finally {
                        // release() used to sit after getFrameAtTime, so a throw
                        // there never ran it: each failed attempt leaked a native
                        // MediaMetadataRetriever, and the gallery retries.
                        frame?.recycle()
                        try {
                            retriever.release()
                        } catch (_: Exception) {
                            // A retriever that throws on release is still released.
                        }
                        if (success == null) temp.delete()
                    }
                    mainHandler.post {
                        when {
                            success != null -> result.success(success)
                            failure != null -> result.error(failure.first, failure.second, null)
                            else -> result.success(null)
                        }
                    }
                }
            } catch (e: RejectedExecutionException) {
                result.error("THUMBNAIL_BUSY", "Thumbnail worker is busy", null)
            }
        } else {
            result.notImplemented()
        }
    }
}
