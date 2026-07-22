pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}

rootProject.name = "onlo-android-example"
include(":app", ":onlo-android-sdk")
project(":onlo-android-sdk").projectDir = file("../../packages/android")
