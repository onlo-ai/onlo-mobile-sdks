import com.android.build.api.dsl.LibraryExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.gradle.api.publish.maven.MavenPublication

plugins {
    id("com.android.library")
    kotlin("android")
    `maven-publish`
}

group = providers.gradleProperty("onlo.maven.group").getOrElse("ai.onlo.unpublished")
version = providers.gradleProperty("onlo.release.version").getOrElse("0.1.0")

extensions.configure<LibraryExtension> {
    namespace = "ai.onlo.sdk"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        buildConfig = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    // Android's framework JSONObject methods are stubs in local JVM tests.
    testImplementation("org.json:json:20240303")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifactId = providers.gradleProperty("onlo.maven.artifact")
                    .getOrElse("onlo-android-sdk")
                pom {
                    name.set("Onlo Android SDK")
                    description.set("Onlo native Android Core and messenger UI.")
                    url.set("https://onlo.ai")
                }
            }
        }
        repositories {
            maven {
                name = "qualification"
                url = uri(
                    providers.gradleProperty("onlo.maven.repository")
                        .getOrElse(layout.buildDirectory.dir("qualification-maven").get().asFile.toURI().toString())
                )
            }
        }
    }
}
