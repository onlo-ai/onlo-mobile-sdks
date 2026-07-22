plugins {
    id("com.android.application")
    kotlin("android")
}

android {
    namespace = "ai.onlo.example"
    compileSdk = 35

    defaultConfig {
        applicationId = "ai.onlo.example"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "0.0.0-local"
    }

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
