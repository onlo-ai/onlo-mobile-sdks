package ai.onlo.example

import ai.onlo.sdk.Onlo
import ai.onlo.sdk.OnloClient
import ai.onlo.sdk.OnloDevelopmentSupport
import ai.onlo.sdk.OnloLogLevel
import android.app.Application

class MerchantApplication : Application() {
    var onloClient: OnloClient? = null
        private set

    override fun onCreate() {
        super.onCreate()
        Onlo.setLogLevel(if (BuildConfig.DEBUG) OnloLogLevel.VERBOSE else OnloLogLevel.OFF)
        val publicSdkKey = BuildConfig.ONLO_SDK_KEY.takeIf(String::isNotBlank) ?: return
        onloClient = initializeOnlo(publicSdkKey)
    }

    @OptIn(OnloDevelopmentSupport::class)
    private fun initializeOnlo(publicSdkKey: String): OnloClient =
        if (BuildConfig.ONLO_DEVELOPMENT_ORIGIN.isBlank()) {
            Onlo.initialize(applicationContext, publicSdkKey)
        } else {
            Onlo.initializeDevelopment(
                applicationContext,
                publicSdkKey,
                BuildConfig.ONLO_DEVELOPMENT_ORIGIN,
            )
        }
}
