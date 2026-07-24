pluginManagement {
    plugins {
        id("com.android.library") version "8.6.1"
        kotlin("android") version "2.0.21"
        id("org.jetbrains.dokka") version "2.2.0"
        id("org.jetbrains.dokka-javadoc") version "2.2.0"
        id("com.vanniktech.maven.publish.base") version "0.34.0"
    }
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "onlo-android-sdk"
