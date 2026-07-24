import java.util.Properties

plugins {
    id("com.android.application")
    kotlin("android")
}

val localProperties = Properties().apply {
    val source = rootProject.file("local.properties")
    if (source.isFile) source.inputStream().use(::load)
}
val onloSdkKey = localProperties.getProperty("ONLO_SDK_KEY", "")
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")
val operatorBackendUrl = localProperties.getProperty("ONLO_OPERATOR_BACKEND_URL", "")
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")

android {
    namespace = "ai.onlo.example"
    compileSdk = 35

    defaultConfig {
        applicationId = "ai.onlo.example"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = providers.gradleProperty("onlo.release.version")
            .getOrElse("0.0.0-local")
        buildConfigField("String", "ONLO_SDK_KEY", "\"$onloSdkKey\"")
        buildConfigField("String", "ONLO_OPERATOR_BACKEND_URL", "\"$operatorBackendUrl\"")
    }

    buildFeatures { buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(project(":onlo-android-sdk"))
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
}
