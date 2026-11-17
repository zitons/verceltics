plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Same public Google OAuth client as iOS (ios/verceltics-Info.plist). Its custom-scheme redirect
// works for the browser PKCE flow on Android too. Forks can override it with the Gradle property.
val googleOAuthClientId = providers.gradleProperty("VERCELTICS_GOOGLE_OAUTH_CLIENT_ID")
    .orNull
    ?.trim()
    ?.takeIf(String::isNotEmpty)
    ?: "804271028953-rc53qhcvdki0rpe2pe98gsahs8dimem7.apps.googleusercontent.com"
val configuredGoogleOAuthRedirectScheme = providers.gradleProperty("VERCELTICS_GOOGLE_OAUTH_REDIRECT_SCHEME")
    .orNull
    ?.trim()
    ?.takeIf(String::isNotEmpty)
val derivedGoogleOAuthRedirectScheme = googleOAuthClientId
    .takeIf { it.endsWith(".apps.googleusercontent.com") }
    ?.removeSuffix(".apps.googleusercontent.com")
    ?.takeIf(String::isNotEmpty)
    ?.let { "com.googleusercontent.apps.$it" }
if (configuredGoogleOAuthRedirectScheme != null &&
    configuredGoogleOAuthRedirectScheme != derivedGoogleOAuthRedirectScheme
) {
    throw GradleException("VERCELTICS_GOOGLE_OAUTH_REDIRECT_SCHEME must be the reverse Google client id.")
}
val googleOAuthRedirectScheme = derivedGoogleOAuthRedirectScheme
    ?: "verceltics-oauth-unconfigured"

// Play upload key, kept outside the repository. Builds without these properties stay unsigned.
val uploadKeystorePath = providers.gradleProperty("VERCELTICS_UPLOAD_KEYSTORE")
    .orNull
    ?.trim()
    ?.takeIf(String::isNotEmpty)
val uploadKeystorePassword = providers.gradleProperty("VERCELTICS_UPLOAD_KEYSTORE_PASSWORD_FILE")
    .orNull
    ?.trim()
    ?.takeIf(String::isNotEmpty)
    ?.let { providers.fileContents(layout.projectDirectory.file(it)).asText.get().trim() }

fun String.asBuildConfigString(): String =
    "\"${replace("\\", "\\\\").replace("\"", "\\\"")}\""

android {
    namespace = "com.apoorvdarshan.verceltics"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.apoorvdarshan.verceltics"
        minSdk = 28
        targetSdk = 36
        versionCode = 45
        versionName = "1.0.1"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true
        buildConfigField(
            "String",
            "GOOGLE_OAUTH_CLIENT_ID",
            googleOAuthClientId.asBuildConfigString(),
        )
        buildConfigField(
            "String",
            "GOOGLE_OAUTH_REDIRECT_SCHEME",
            googleOAuthRedirectScheme.asBuildConfigString(),
        )
        manifestPlaceholders["googleOAuthRedirectScheme"] = googleOAuthRedirectScheme
        // Release uses @string/app_name; debug overrides it to "Verceltics Debug".
        manifestPlaceholders["launcherAppName"] = "@string/app_name"
    }

    signingConfigs {
        if (uploadKeystorePath != null && uploadKeystorePassword != null) {
            create("upload") {
                storeFile = file(uploadKeystorePath)
                storePassword = uploadKeystorePassword
                keyAlias = "upload"
                keyPassword = uploadKeystorePassword
            }
        }
    }

    buildTypes {
        debug {
            // Installs side by side with the Play app, so test builds never replace it
            // or its data. Launcher label matches the other apps: "Verceltics Debug".
            applicationIdSuffix = ".debug"
            manifestPlaceholders["launcherAppName"] = "Verceltics Debug"
        }
        release {
            signingConfig = signingConfigs.findByName("upload")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

// CI restores the Gradle build cache. Test results must never come from it: every
// run executes the unit tests again, while compiled classes can still be reused. Unit
// tests also read files that are not task inputs (ProviderApiCatalogParserTest compares
// the bundled catalog with ios/verceltics/Resources/ProviderAPICatalog.json), so a
// cached result could hide a change to them.
tasks.withType<Test>().configureEach {
    outputs.doNotCacheIf("test results are never restored from the build cache") { true }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")

    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    // Google Play In-App Updates and In-App Review. Both degrade to no-ops on sideloaded builds.
    implementation("com.google.android.play:app-update:2.1.0")
    implementation("com.google.android.play:app-update-ktx:2.1.0")
    implementation("com.google.android.play:review:2.0.2")
    implementation("com.google.android.play:review-ktx:2.0.2")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
