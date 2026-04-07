package com.clawdphone.app.services

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Minimal NotificationListenerService so the app appears in
 * Android's "Notification Access" settings page.
 *
 * When the user grants notification access, this service receives
 * notifications which can be queried by the Notifications tool.
 */
class NotificationService : NotificationListenerService() {

    companion object {
        /** Static reference so PersonalToolsChannel can read active notifications */
        @Volatile
        var instance: NotificationService? = null
            private set
    }

    override fun onListenerConnected() {
        instance = this
    }

    override fun onListenerDisconnected() {
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        // No-op — notifications are read on demand via getActiveNotifications()
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // No-op
    }
}
