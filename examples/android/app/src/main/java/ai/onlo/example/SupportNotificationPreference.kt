package ai.onlo.example

import android.content.Context

/** Stores only the customer's app-level opt-in. Provider tokens remain in native protected storage. */
internal object SupportNotificationPreference {
    private const val FILE_NAME = "onlo_example_preferences"
    private const val ENABLED_KEY = "support_notifications_enabled"

    fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .getBoolean(ENABLED_KEY, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(ENABLED_KEY, enabled)
            .apply()
    }
}
