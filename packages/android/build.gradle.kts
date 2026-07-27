import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.jvm.tasks.Jar
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    kotlin("android")
    id("org.jetbrains.dokka")
    id("org.jetbrains.dokka-javadoc")
    id("com.vanniktech.maven.publish.base")
    `maven-publish`
}

group = providers.gradleProperty("onlo.maven.group").getOrElse("ai.onlo")
val canonicalVersionFile = project.file("../../VERSION")
require(canonicalVersionFile.isFile) { "Missing canonical VERSION file" }
val canonicalVersion = canonicalVersionFile.readText().trim()
val onloReleaseVersion = providers.gradleProperty("onlo.release.version").getOrElse(canonicalVersion)
require(Regex("[0-9]+\\.[0-9]+\\.[0-9]+").matches(onloReleaseVersion)) {
    "onlo.release.version must be a semantic version"
}
require(onloReleaseVersion == canonicalVersion) {
    "onlo.release.version must match the canonical VERSION file"
}
version = onloReleaseVersion

extensions.configure<LibraryExtension> {
    namespace = "ai.onlo.sdk"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "ONLO_SDK_VERSION", "\"$onloReleaseVersion\"")
    }

    buildFeatures {
        buildConfig = true
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

val dokkaJavadocJar by tasks.registering(Jar::class) {
    description = "Packages the public Android SDK API reference for Maven Central."
    dependsOn(tasks.dokkaGeneratePublicationJavadoc)
    from(tasks.dokkaGeneratePublicationJavadoc.flatMap { it.outputDirectory })
    archiveClassifier.set("javadoc")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifact(dokkaJavadocJar)
                artifactId = providers.gradleProperty("onlo.maven.artifact")
                    .getOrElse("onlo-android-sdk")
                pom {
                    name.set("Onlo Android SDK")
                    description.set("Onlo native Android Core and messenger UI.")
                    url.set("https://github.com/onlo-ai/onlo-mobile-sdks")
                    licenses {
                        license {
                            name.set("Onlo Proprietary License")
                            url.set("https://github.com/onlo-ai/onlo-mobile-sdks/blob/main/LICENSE")
                            distribution.set("repo")
                        }
                    }
                    developers {
                        developer {
                            id.set("onlo")
                            name.set("Onlo")
                            email.set("support@onlo.ai")
                            organization.set("Onlo")
                            organizationUrl.set("https://onlo.ai")
                        }
                    }
                    scm {
                        connection.set("scm:git:https://github.com/onlo-ai/onlo-mobile-sdks.git")
                        developerConnection.set("scm:git:ssh://git@github.com/onlo-ai/onlo-mobile-sdks.git")
                        url.set("https://github.com/onlo-ai/onlo-mobile-sdks")
                    }
                    withXml {
                        asNode().appendNode("issueManagement").apply {
                            appendNode("system", "GitHub")
                            appendNode("url", "https://github.com/onlo-ai/onlo-mobile-sdks/issues")
                        }
                    }
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

if (providers.gradleProperty("onlo.maven.central").orNull == "true") {
    mavenPublishing {
        publishToMavenCentral(automaticRelease = true)
        signAllPublications()
    }
}
