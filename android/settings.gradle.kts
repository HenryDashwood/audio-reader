pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "Magpie"
include(":app")
// The natural voice's asset pack, when its files are here: see natural_voice/build.gradle.kts.
if (file("natural_voice/src/main/assets/NaturalVoice/voice.json").isFile) include(":natural_voice")
