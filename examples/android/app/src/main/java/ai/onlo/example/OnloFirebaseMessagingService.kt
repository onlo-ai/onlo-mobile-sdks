package ai.onlo.example

import ai.onlo.sdk.protocol.PushProvider
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class OnloFirebaseMessagingService : FirebaseMessagingService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onNewToken(token: String) {
        if (!SupportNotificationPreference.isEnabled(this)) {
            OnloFcmDiagnostics.info("event=rotated_token_skipped reason=notifications_disabled")
            return
        }
        val client = (application as? MerchantApplication)?.onloClient
        if (client == null) {
            OnloFcmDiagnostics.warn("event=rotated_token_skipped reason=client_unavailable")
            return
        }
        OnloFcmDiagnostics.info("event=rotated_token_registration_started")
        serviceScope.launch {
            try {
                val outcome = client.registerPushToken(PushProvider.FCM, token)
                OnloFcmDiagnostics.info("event=rotated_token_registration_completed outcome=${outcome.javaClass.simpleName}")
            } catch (error: Exception) {
                OnloFcmDiagnostics.warn("event=rotated_token_registration_failed errorClass=${error.javaClass.simpleName}")
            }
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val payload = message.data
        OnloFcmDiagnostics.info("event=message_received fieldCount=${payload.size}")
        if (payload.keys != ONLO_PAYLOAD_KEYS ||
            payload["notificationType"] != NOTIFICATION_TYPE
        ) {
            OnloFcmDiagnostics.warn("event=message_rejected reason=payload_contract fieldCount=${payload.size}")
            return
        }

        val conversationId = payload["conversationId"]?.takeIf(String::isNotBlank)
        if (conversationId == null) {
            OnloFcmDiagnostics.warn("event=message_rejected reason=conversation_id_missing")
            return
        }
        val messageId = payload["messageId"]?.takeIf(String::isNotBlank)
        if (messageId == null) {
            OnloFcmDiagnostics.warn("event=message_rejected reason=message_id_missing")
            return
        }
        try {
            postNotification(conversationId, messageId)
            OnloFcmDiagnostics.info("event=notification_posted")
        } catch (error: RuntimeException) {
            OnloFcmDiagnostics.warn("event=notification_post_failed errorClass=${error.javaClass.simpleName}")
        }
    }

    private fun postNotification(conversationId: String, messageId: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Customer support",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("conversationId", conversationId)
            putExtra("messageId", messageId)
            putExtra("notificationType", NOTIFICATION_TYPE)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            conversationId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            messageId.hashCode(),
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setContentTitle("New support reply")
                .setContentText("Open Support to view the message.")
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build(),
        )
    }

    private companion object {
        const val CHANNEL_ID = "onlo_support"
        const val NOTIFICATION_TYPE = "message_available"
        val ONLO_PAYLOAD_KEYS = setOf("conversationId", "messageId", "notificationType")
    }
}
