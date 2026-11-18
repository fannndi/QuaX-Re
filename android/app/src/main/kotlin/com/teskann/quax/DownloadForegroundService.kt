package com.teskann.quax

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Keeps the app process alive while a transfer runs (so downloads survive the
 * app being backgrounded) and mirrors the progress in a foreground
 * notification with Pause/Cancel actions. Android stops the service — and its
 * notification — as soon as the download queue goes idle.
 */
class DownloadForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "downloads"
        const val NOTIFICATION_ID = 4711
        const val ACTION_PAUSE = "com.teskann.quax.download.PAUSE"
        const val ACTION_CANCEL = "com.teskann.quax.download.CANCEL"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_PERCENT = "percent"
        const val EXTRA_FILE = "fileName"
        const val EXTRA_PAUSE_LABEL = "pauseLabel"
        const val EXTRA_CANCEL_LABEL = "cancelLabel"

        fun start(context: Context, intent: Intent) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ refuses a foreground start from the background.
                // Logging it matters: the transfer keeps running in a cached
                // process, which the system may freeze or kill, and this line
                // is the only trace that the protection was never there.
                android.util.Log.w("DownloadService", "foreground start refused", e)
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, DownloadForegroundService::class.java))
            } catch (e: Exception) {
                // Already gone.
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE, ACTION_CANCEL -> {
                val action = if (intent.action == ACTION_PAUSE) "pause" else "cancel"
                QuaxApplication.channel?.invokeMethod(
                    "onDownloadAction",
                    mapOf("action" to action, "fileName" to intent.getStringExtra(EXTRA_FILE))
                )
                return START_NOT_STICKY
            }
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "QuaX"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: ""
        val percent = intent?.getIntExtra(EXTRA_PERCENT, 0) ?: 0
        val fileName = intent?.getStringExtra(EXTRA_FILE) ?: ""
        val pauseLabel = intent?.getStringExtra(EXTRA_PAUSE_LABEL) ?: "Pause"
        val cancelLabel = intent?.getStringExtra(EXTRA_CANCEL_LABEL) ?: "Cancel"

        createChannel()
        val notification = buildNotification(title, body, percent, fileName, pauseLabel, cancelLabel)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            START_NOT_STICKY
        } catch (e: Exception) {
            // A startForeground() that throws on the main thread used to take
            // the whole process down with it, mid-transfer.
            android.util.Log.w("DownloadService", "startForeground failed", e)
            stopSelf(startId)
            START_NOT_STICKY
        }
    }

    /**
     * Android 15 caps a dataSync service at six hours a day. Without this
     * override the system kills the app with
     * ForegroundServiceDidNotStopInTimeException instead of letting the queue
     * end cleanly.
     */
    override fun onTimeout(startId: Int) {
        android.util.Log.w("DownloadService", "dataSync budget exhausted; stopping")
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        onTimeout(startId)
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW)
                channel.description = "Media download progress."
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun buildNotification(
        title: String,
        body: String,
        percent: Int,
        fileName: String,
        pauseLabel: String,
        cancelLabel: String
    ): Notification {
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        // getLaunchIntentForPackage is nullable: a null intent made
        // PendingIntent.getActivity throw on the service's main thread.
        val contentIntent = openIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        fun actionIntent(action: String, requestCode: Int): PendingIntent = PendingIntent.getService(
            this,
            requestCode,
            Intent(this, DownloadForegroundService::class.java)
                .setAction(action)
                .putExtra(EXTRA_FILE, fileName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, percent.coerceIn(0, 100), percent <= 0)
            .addAction(0, pauseLabel, actionIntent(ACTION_PAUSE, 1))
            .addAction(0, cancelLabel, actionIntent(ACTION_CANCEL, 2))
        if (contentIntent != null) builder.setContentIntent(contentIntent)
        return builder.build()
    }
}
