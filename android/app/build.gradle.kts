import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.devtools.ksp")
}

ksp { arg("appfunctions:aggregateAppFunctions", "true") }

// Release credentials are supplied outside Git. These values never enter BuildConfig.
val releaseKeys = listOf("MAGPIE_RELEASE_STORE_FILE", "MAGPIE_RELEASE_STORE_PASSWORD",
    "MAGPIE_RELEASE_KEY_ALIAS", "MAGPIE_RELEASE_KEY_PASSWORD", "MAGPIE_RELEASE_OAUTH_SHA1")
val releaseValues = releaseKeys.associateWith { providers.gradleProperty(it).orElse("").get() }
val releaseServer = providers.gradleProperty("MAGPIE_ACCOUNT_API_URL")
    .orElse("https://audio-reader-production.up.railway.app").get()
val releaseGoogleClient = providers.gradleProperty("MAGPIE_GOOGLE_SERVER_CLIENT_ID")
    .orElse("102154849961-o07dgdc8ltoescp4p3k9knl8rlm1l4m7.apps.googleusercontent.com").get()
val validateReleaseSetup = tasks.register("validateReleaseSetup") {
    group = "verification"
    description = "Verify private release signing inputs and the declared OAuth certificate before building."
    doLast {
        val missing = releaseKeys.filter { releaseValues.getValue(it).isBlank() }
        check(missing.isEmpty()) { "Release setup is incomplete: ${missing.joinToString()}. See docs/android-release.md." }
        check(releaseServer.matches(Regex("https://[A-Za-z0-9.-]+(:[0-9]+)?/?"))) { "Supply an HTTPS release API origin." }
        check(releaseGoogleClient.endsWith(".apps.googleusercontent.com")) { "Supply the registered Google server OAuth client ID." }
        val keyFile = file(releaseValues.getValue("MAGPIE_RELEASE_STORE_FILE"))
        check(keyFile.isFile) { "The release keystore file is unavailable. See docs/android-release.md." }
        val store = KeyStore.getInstance(keyFile, releaseValues.getValue("MAGPIE_RELEASE_STORE_PASSWORD").toCharArray())
        val alias = releaseValues.getValue("MAGPIE_RELEASE_KEY_ALIAS")
        check(store.isKeyEntry(alias)) { "The release alias does not identify a signing key." }
        check(store.getKey(alias, releaseValues.getValue("MAGPIE_RELEASE_KEY_PASSWORD").toCharArray()) != null) { "The signing key could not be opened." }
        val fingerprint = MessageDigest.getInstance("SHA-1").digest(store.getCertificate(alias).encoded)
            .joinToString("") { "%02X".format(it) }
        val registered = releaseValues.getValue("MAGPIE_RELEASE_OAUTH_SHA1").replace(":", "").uppercase()
        check(registered.matches(Regex("[A-F0-9]{40}")) && fingerprint == registered) {
            "The signing certificate differs from MAGPIE_RELEASE_OAUTH_SHA1. Register this exact release certificate with Google first."
        }
    }
}
tasks.matching { it.name == "preReleaseBuild" }.configureEach { dependsOn(validateReleaseSetup) }

android {
    namespace = "com.henrydashwood.magpie"
    compileSdk = 37
    defaultConfig {
        applicationId = "com.henrydashwood.magpie"
        minSdk = 31
        targetSdk = 37
        val googleClient = providers.gradleProperty("MAGPIE_GOOGLE_SERVER_CLIENT_ID").orElse("").get()
        val accountServer = providers.gradleProperty("MAGPIE_ACCOUNT_API_URL").orElse("").get()
        require(googleClient.matches(Regex("[A-Za-z0-9._-]*")))
        require(accountServer.isEmpty() || accountServer.matches(Regex("https://[A-Za-z0-9.-]+(:[0-9]+)?/?")))
        buildConfigField("String", "GOOGLE_SERVER_CLIENT_ID", "\"$googleClient\"")
        buildConfigField("String", "ACCOUNT_API_URL", "\"$accountServer\"")
        versionCode = 1
        versionName = "0.1.0-prototype"
        testInstrumentationRunner = "com.henrydashwood.magpie.MagpieTestRunner"
    }
    signingConfigs {
        create("release") {
            if (releaseKeys.all { releaseValues.getValue(it).isNotBlank() }) {
                storeFile = file(releaseValues.getValue("MAGPIE_RELEASE_STORE_FILE"))
                storePassword = releaseValues.getValue("MAGPIE_RELEASE_STORE_PASSWORD")
                keyAlias = releaseValues.getValue("MAGPIE_RELEASE_KEY_ALIAS")
                keyPassword = releaseValues.getValue("MAGPIE_RELEASE_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            require(releaseGoogleClient.matches(Regex("[A-Za-z0-9._-]*")))
            require(releaseServer.isEmpty() || releaseServer.matches(Regex("https://[A-Za-z0-9.-]+(:[0-9]+)?/?")))
            signingConfig = signingConfigs.getByName("release")
            buildConfigField("String", "GOOGLE_SERVER_CLIENT_ID", "\"$releaseGoogleClient\"")
            buildConfigField("String", "ACCOUNT_API_URL", "\"$releaseServer\"")
        }
        debug {
            applicationIdSuffix = ".dev"
            // Public IDs for the registered development build. Release remains
            // opt-in until its actual signing certificate is registered.
            val googleClient = providers.gradleProperty("MAGPIE_GOOGLE_SERVER_CLIENT_ID")
                .orElse("102154849961-o07dgdc8ltoescp4p3k9knl8rlm1l4m7.apps.googleusercontent.com").get()
            val accountServer = providers.gradleProperty("MAGPIE_ACCOUNT_API_URL")
                .orElse("https://audio-reader-staging.up.railway.app").get()
            buildConfigField("String", "GOOGLE_SERVER_CLIENT_ID", "\"$googleClient\"")
            buildConfigField("String", "ACCOUNT_API_URL", "\"$accountServer\"")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.08.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")
    implementation("androidx.appfunctions:appfunctions:1.0.0-alpha11")
    ksp("androidx.appfunctions:appfunctions-compiler:1.0.0-alpha11")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("org.jsoup:jsoup:1.23.2")
    implementation("io.coil-kt.coil3:coil-compose:3.6.2")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.6.2")
    androidTestImplementation("io.coil-kt.coil3:coil-test:3.6.2")
    implementation("androidx.browser:browser:1.10.0")
    implementation("androidx.credentials:credentials:1.6.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.6.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.2.1")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    // Older transitive Espresso versions reflect on InputManager APIs removed in API 36.1.
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// The same pinned Readability extraction used by Safari; keep one source and license.
abstract class CaptureAssetsTask : DefaultTask() {
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE)
    abstract val scriptFile: RegularFileProperty
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE)
    abstract val licenseFile: RegularFileProperty
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
    @TaskAction fun copyAssets() {
        val destination = outputDirectory.dir("capture").get().asFile.apply { mkdirs() }
        scriptFile.get().asFile.copyTo(destination.resolve("CapturePage.js"), overwrite = true)
        licenseFile.get().asFile.copyTo(destination.resolve("Readability-LICENSE.txt"), overwrite = true)
    }
}
val captureAssets = tasks.register<CaptureAssetsTask>("captureAssets") {
    scriptFile.set(rootProject.file("../ios/HearfulShare/CapturePage.js"))
    licenseFile.set(rootProject.file("../ios/HearfulShare/Readability-LICENSE.txt"))
    outputDirectory.set(layout.buildDirectory.dir("generated/captureAssets"))
}
androidComponents.onVariants { variant ->
    variant.sources.assets?.addGeneratedSourceDirectory(captureAssets, CaptureAssetsTask::outputDirectory)
}
