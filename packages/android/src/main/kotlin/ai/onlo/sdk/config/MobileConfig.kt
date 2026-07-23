package ai.onlo.sdk.config

import ai.onlo.sdk.protocol.Capability
import ai.onlo.sdk.protocol.ProtocolViolation
import ai.onlo.sdk.protocol.requiredBoolean
import ai.onlo.sdk.protocol.requiredInt
import ai.onlo.sdk.protocol.requiredObject
import ai.onlo.sdk.protocol.requiredString
import org.json.JSONArray
import org.json.JSONObject

/** Strict, read-only representation of the server-owned mobile configuration schema v1. */
public data class MobileConfig(
    val schemaVersion: Int,
    val revision: String,
    val compatibility: Compatibility,
    val securityPolicy: SecurityPolicy,
    val appearance: Appearance,
    val features: Features,
    val mediaPolicy: MediaPolicy,
    val content: Content,
    val identityMode: String,
    val unsupportedWidgetSettings: List<UnsupportedWidgetSetting>,
) {
    public data class Compatibility(val requestedSchemaVersion: Int, val appliedSchemaVersion: Int, val capabilities: List<Capability>, val unsupportedSettings: List<UnsupportedSetting>)
    public data class UnsupportedSetting(val code: String, val setting: String, val reason: String, val requiredCapabilities: List<Capability>?)
    public data class SecurityPolicy(val minimumProtocolVersion: Int, val minimumSdkVersion: String?, val identityMode: String, val anonymousScope: String, val nativePlacement: String)
    public data class Appearance(val accent: String, val botName: String, val botSubtitle: String, val greeting: String, val headerAvatar: HeaderAvatar, val light: ColorTheme, val dark: DarkColorTheme)
    public data class HeaderAvatar(val mode: HeaderAvatarMode, val text: String, val data: String?)
    public enum class HeaderAvatarMode { IMAGE, INITIALS }
    public data class ColorTheme(val background: String, val outgoing: String, val outgoingText: String, val incoming: String, val incomingText: String)
    /** This maps the contract's flat `ColorTheme & { enabled }` shape exactly. */
    public data class DarkColorTheme(val enabled: Boolean, val background: String, val outgoing: String, val outgoingText: String, val incoming: String, val incomingText: String)
    public data class Features(val insertLink: Boolean, val insertCode: Boolean, val emoji: Boolean, val gifs: Boolean, val voice: Boolean, val fileUpload: Boolean, val transcriptDownload: Boolean, val soundNotifications: Boolean, val showTimestamps: Boolean, val faqButton: FaqButton)
    public data class MediaPolicy(val enabled: Boolean, val maximumImagesPerMessage: Int, val maximumImageBytes: Int) {
        public val effectiveMaximumImagesPerMessage: Int get() = maximumImagesPerMessage.coerceAtMost(5)
        public val effectiveMaximumImageBytes: Int get() = maximumImageBytes.coerceAtMost(8_388_608)
    }
    public data class FaqButton(val enabled: Boolean, val label: String)
    public data class Content(val faqs: List<Faq>, val tabs: Tabs, val search: Search, val onboarding: Onboarding, val homeSections: List<HomeSection>)
    public data class Faq(val question: String, val answer: String?)
    public data class Tabs(val enabled: Boolean, val tabs: List<Tab>, val defaultTab: String)
    public data class Tab(val id: String, val label: String, val icon: String, val enabled: Boolean)
    public data class Search(val enabled: Boolean, val placeholder: String, val showSearchInHome: Boolean)
    public data class Onboarding(val enabled: Boolean, val title: String, val showProgress: Boolean, val items: List<OnboardingItem>)
    public data class OnboardingItem(val id: String, val title: String, val description: String?, val completed: Boolean, val actionUrl: String?)
    public data class HomeSection(val id: String, val type: HomeSectionType, val title: String?, val content: String?, val enabled: Boolean, val order: Int)
    public enum class HomeSectionType { WELCOME, SEARCH, FAQS, CHECKLIST, CUSTOM }
    public data class UnsupportedWidgetSetting(val setting: String, val reason: String)
}

/** The raw JSON is retained only in encrypted native storage after this decoder accepts it. */
internal object MobileConfigCodec {
    fun decode(raw: String): MobileConfig = decode(JSONObject(raw))

    fun decode(value: JSONObject): MobileConfig {
        val config = MobileConfig(
            schemaVersion = value.requiredInt("schemaVersion").also { requireProtocol(it == 1, "config_schema") },
            revision = value.requiredString("revision"),
            compatibility = decodeCompatibility(value.requiredObject("compatibility")),
            securityPolicy = decodeSecurity(value.requiredObject("securityPolicy")),
            appearance = decodeAppearance(value.requiredObject("appearance")),
            features = decodeFeatures(value.requiredObject("features")),
            mediaPolicy = decodeMediaPolicy(value.requiredObject("mediaPolicy")),
            content = decodeContent(value.requiredObject("content")),
            identityMode = value.requiredString("identityMode"),
            unsupportedWidgetSettings = array(value, "unsupportedWidgetSettings").map { item ->
                MobileConfig.UnsupportedWidgetSetting(item.requiredString("setting"), item.requiredString("reason"))
            },
        )
        requireProtocol(config.compatibility.requestedSchemaVersion == 1 && config.compatibility.appliedSchemaVersion == 1, "config_compatibility")
        requireProtocol(config.securityPolicy.minimumProtocolVersion == 1, "config_protocol")
        requireProtocol(config.securityPolicy.identityMode == "sdk_interface" && config.identityMode == "sdk_interface", "config_identity_mode")
        requireProtocol(config.securityPolicy.anonymousScope == "installation_generation", "config_anonymous_scope")
        requireProtocol(config.securityPolicy.nativePlacement == "host_app", "config_native_placement")
        return config
    }

    private fun decodeCompatibility(v: JSONObject) = MobileConfig.Compatibility(
        v.requiredInt("requestedSchemaVersion"), v.requiredInt("appliedSchemaVersion"),
        stringArray(v, "capabilities").map(::capability),
        array(v, "unsupportedSettings").map { item -> MobileConfig.UnsupportedSetting(item.requiredString("code"), item.requiredString("setting"), item.requiredString("reason"), optionalStringArray(item, "requiredCapabilities")?.map(::capability)) },
    )
    private fun decodeSecurity(v: JSONObject) = MobileConfig.SecurityPolicy(v.requiredInt("minimumProtocolVersion"), requiredNullableString(v, "minimumSdkVersion"), v.requiredString("identityMode"), v.requiredString("anonymousScope"), v.requiredString("nativePlacement"))
    private fun decodeAppearance(v: JSONObject): MobileConfig.Appearance {
        val avatar = v.requiredObject("headerAvatar")
        val mode = when (avatar.requiredString("mode")) { "image" -> MobileConfig.HeaderAvatarMode.IMAGE; "initials" -> MobileConfig.HeaderAvatarMode.INITIALS; else -> throw ProtocolViolation("header_avatar_mode") }
        val dark = v.requiredObject("dark")
        return MobileConfig.Appearance(v.requiredString("accent"), v.requiredString("botName"), v.requiredString("botSubtitle"), v.requiredString("greeting"), MobileConfig.HeaderAvatar(mode, avatar.requiredString("text"), requiredNullableString(avatar, "data")), colors(v.requiredObject("light")), MobileConfig.DarkColorTheme(dark.requiredBoolean("enabled"), dark.requiredString("background"), dark.requiredString("outgoing"), dark.requiredString("outgoingText"), dark.requiredString("incoming"), dark.requiredString("incomingText")))
    }
    private fun colors(v: JSONObject) = MobileConfig.ColorTheme(v.requiredString("background"), v.requiredString("outgoing"), v.requiredString("outgoingText"), v.requiredString("incoming"), v.requiredString("incomingText"))
    private fun decodeFeatures(v: JSONObject): MobileConfig.Features {
        val faq = v.requiredObject("faqButton")
        return MobileConfig.Features(v.requiredBoolean("insertLink"), v.requiredBoolean("insertCode"), v.requiredBoolean("emoji"), v.requiredBoolean("gifs"), v.requiredBoolean("voice"), v.requiredBoolean("fileUpload"), v.requiredBoolean("transcriptDownload"), v.requiredBoolean("soundNotifications"), v.requiredBoolean("showTimestamps"), MobileConfig.FaqButton(faq.requiredBoolean("enabled"), faq.requiredString("label")))
    }
    private fun decodeMediaPolicy(v: JSONObject): MobileConfig.MediaPolicy {
        val maximumImagesPerMessage = v.requiredInt("maximumImagesPerMessage")
        val maximumImageBytes = v.requiredInt("maximumImageBytes")
        requireProtocol(maximumImagesPerMessage in 0..5, "config_media_maximum_images")
        requireProtocol(maximumImageBytes in 1..8_388_608, "config_media_maximum_bytes")
        return MobileConfig.MediaPolicy(v.requiredBoolean("enabled"), maximumImagesPerMessage, maximumImageBytes)
    }
    private fun decodeContent(v: JSONObject) = MobileConfig.Content(
        array(v, "faqs").map { MobileConfig.Faq(it.requiredString("question"), optionalString(it, "answer")) },
        decodeTabs(v.requiredObject("tabs")),
        v.requiredObject("search").let { MobileConfig.Search(it.requiredBoolean("enabled"), it.requiredString("placeholder"), it.requiredBoolean("showSearchInHome")) },
        decodeOnboarding(v.requiredObject("onboarding")),
        array(v, "homeSections").map { item -> MobileConfig.HomeSection(item.requiredString("id"), homeType(item.requiredString("type")), optionalString(item, "title"), optionalString(item, "content"), item.requiredBoolean("enabled"), item.requiredInt("order")) },
    )
    private fun decodeTabs(v: JSONObject) = MobileConfig.Tabs(v.requiredBoolean("enabled"), array(v, "tabs").map { MobileConfig.Tab(it.requiredString("id"), it.requiredString("label"), it.requiredString("icon"), it.requiredBoolean("enabled")) }, v.requiredString("defaultTab"))
    private fun decodeOnboarding(v: JSONObject) = MobileConfig.Onboarding(v.requiredBoolean("enabled"), v.requiredString("title"), v.requiredBoolean("showProgress"), array(v, "items").map { MobileConfig.OnboardingItem(it.requiredString("id"), it.requiredString("title"), optionalString(it, "description"), it.requiredBoolean("completed"), optionalString(it, "actionUrl")) })
    private fun homeType(value: String): MobileConfig.HomeSectionType = when (value) { "welcome" -> MobileConfig.HomeSectionType.WELCOME; "search" -> MobileConfig.HomeSectionType.SEARCH; "faqs" -> MobileConfig.HomeSectionType.FAQS; "checklist" -> MobileConfig.HomeSectionType.CHECKLIST; "custom" -> MobileConfig.HomeSectionType.CUSTOM; else -> throw ProtocolViolation("home_section_type") }
    private fun capability(value: String): Capability = Capability.entries.firstOrNull { it.wireValue == value } ?: throw ProtocolViolation("config_capability")
    private fun array(v: JSONObject, name: String): List<JSONObject> = try { (v.get(name) as? JSONArray ?: throw ProtocolViolation(name)).let { values -> List(values.length()) { index -> values.get(index) as? JSONObject ?: throw ProtocolViolation(name) } } } catch (e: ProtocolViolation) { throw e } catch (_: Exception) { throw ProtocolViolation(name) }
    private fun stringArray(v: JSONObject, name: String): List<String> = try { (v.get(name) as? JSONArray ?: throw ProtocolViolation(name)).let { values -> List(values.length()) { index -> values.get(index) as? String ?: throw ProtocolViolation(name) } } } catch (e: ProtocolViolation) { throw e } catch (_: Exception) { throw ProtocolViolation(name) }
    private fun optionalStringArray(v: JSONObject, name: String): List<String>? = if (!v.has(name) || v.isNull(name)) null else stringArray(v, name)
    private fun optionalString(v: JSONObject, name: String): String? = if (!v.has(name) || v.isNull(name)) null else v.requiredString(name)
    private fun requiredNullableString(v: JSONObject, name: String): String? { if (!v.has(name)) throw ProtocolViolation(name); return if (v.isNull(name)) null else v.requiredString(name) }
    private fun requireProtocol(condition: Boolean, code: String) { if (!condition) throw ProtocolViolation(code) }
}
