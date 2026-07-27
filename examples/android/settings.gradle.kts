pluginManagement {
    plugins {
        id("org.jetbrains.dokka") version "2.2.0"
        id("org.jetbrains.dokka-javadoc") version "2.2.0"
        id("com.vanniktech.maven.publish.base") version "0.34.0"
    }
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}

rootProject.name = "onlo-android-example"
include(":app", ":onlo-android-sdk")
project(":onlo-android-sdk").projectDir = file("../../packages/android")
