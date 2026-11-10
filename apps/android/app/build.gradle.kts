import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    // Reads app/google-services.json (the Firebase project for push).
    alias(libs.plugins.google.services)
}

fun prop(name: String): String = (project.findProperty(name) as String?) ?: ""

// Release signing (the Play upload key). keystore.properties and the .jks stay out of git;
// make them with tools/make-upload-key.sh. Without them, release builds come out unsigned.
val keystoreProps = Properties().apply {
    rootProject.file("keystore.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

android {
    namespace = "site.table1.events"
    compileSdk = 36

    defaultConfig {
        applicationId = "site.table1.events"
        minSdk = 26
        targetSdk = 36
        // Play needs a higher versionCode on every upload; tools/bundle-release.sh passes one.
        versionCode = prop("T1_VERSION_CODE").toIntOrNull() ?: 1
        versionName = "0.1.0"
        buildConfigField("String", "SUPABASE_URL", "\"${prop("T1_SUPABASE_URL")}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${prop("T1_SUPABASE_ANON_KEY")}\"")
        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"${prop("T1_GOOGLE_WEB_CLIENT_ID")}\"")
        // Sentry and PostHog (contract/telemetry-2026-10-15.md): an empty DSN / key = off. Debug builds send nothing
        // unless built with -PT1_TELEMETRY=1. Release builds report T1_ENVIRONMENT (testflight or production).
        buildConfigField("String", "SENTRY_DSN", "\"${prop("T1_SENTRY_DSN")}\"")
        buildConfigField("String", "POSTHOG_KEY", "\"${prop("T1_POSTHOG_KEY")}\"")
        buildConfigField("String", "POSTHOG_HOST", "\"${prop("T1_POSTHOG_HOST").ifEmpty { "https://us.i.posthog.com" }}\"")
        buildConfigField("boolean", "TELEMETRY_IN_DEBUG", (prop("T1_TELEMETRY") == "1").toString())
        buildConfigField("String", "RELEASE_ENVIRONMENT", "\"${prop("T1_ENVIRONMENT").ifEmpty { "production" }}\"")
    }

    signingConfigs {
        if (keystoreProps.isNotEmpty()) {
            create("release") {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    // The widget gallery draws with the app's resources (Robolectric).
    testOptions { unitTests.isIncludeAndroidResources = true }
    // The feature spots (contract/feature-spots-2026-11-01.md): copy and phone shots shared with the web and iOS,
    // bundled as assets/spots/ (spots.json, shots/<key>.png).
    sourceSets.getByName("main").assets.srcDir("../../../marketing/bundle")
}

// The widget gallery is design QA, not a check: it runs only when asked, e.g.
// ./gradlew testDebugUnitTest -PT1_WIDGET_GALLERY --tests '*WidgetGalleryTest' → app/build/widget-gallery/*.png
tasks.withType<Test>().configureEach {
    if (!project.hasProperty("T1_WIDGET_GALLERY")) exclude("**/WidgetGalleryTest*")
    systemProperty("t1.widgetGallery", layout.buildDirectory.dir("widget-gallery").get().asFile.path)
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.window)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    debugImplementation(libs.compose.ui.tooling)

    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    implementation(libs.supabase.postgrest)
    implementation(libs.supabase.realtime)
    implementation(libs.supabase.functions)
    implementation(libs.supabase.storage)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.play.services)

    implementation(libs.androidx.credentials)
    implementation(libs.androidx.credentials.play)
    implementation(libs.google.id)
    implementation(libs.play.code.scanner)
    implementation(libs.play.location)
    implementation(libs.zxing.core)
    implementation(libs.installreferrer)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
    implementation(libs.coil.compose)
    implementation(libs.coil.svg)
    implementation(libs.coil.network.okhttp)
    implementation(libs.camerax.camera2)
    implementation(libs.camerax.lifecycle)
    implementation(libs.camerax.view)
    // Home screen widgets (contract/widgets-2026-10-22.md): Next event, Collection value, Current match.
    implementation(libs.glance.appwidget)
    implementation(libs.mlkit.text)
    implementation(libs.mlkit.text.chinese)
    implementation(libs.mlkit.text.japanese)
    implementation(libs.mlkit.text.korean)

    implementation(libs.sentry.android.core)
    implementation(libs.sentry.android.ndk)
    implementation(libs.sentry.okhttp)
    implementation(libs.posthog.android)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    // Compose state checks under Robolectric (KeptScrollTest).
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
}

// ReleaseChecks: every GlanceAppWidget must survive R8 whole and under its own name. Glance finds a widget's ids by its
// provider's class name; when R8 merged the three widget classes into one, every widget turned into Collection value
// (2026-11-02). Runs after R8 on each release build and fails it when a widget class is missing or renamed.
tasks.matching { it.name == "minifyReleaseWithR8" }.configureEach {
    doLast {
        val mapping = layout.buildDirectory.file("outputs/mapping/release/mapping.txt").get().asFile
        if (!mapping.exists()) return@doLast
        val widgets = fileTree("src/main/java").matching { include("**/*.kt") }.files.flatMap { f ->
            val pkg = Regex("^package ([\\w.]+)", RegexOption.MULTILINE).find(f.readText())?.groupValues?.get(1) ?: return@flatMap emptyList()
            Regex("class (\\w+)\\s*:\\s*GlanceAppWidget\\(").findAll(f.readText()).map { "$pkg.${it.groupValues[1]}" }.toList()
        }
        val kept = mapping.useLines { lines ->
            lines.filter { !it.startsWith(" ") && !it.startsWith("#") }
                .mapNotNull { Regex("^(\\S+) -> (\\S+):$").find(it)?.destructured?.let { (from, to) -> from to to } }.toMap()
        }
        val bad = widgets.filter { kept[it] != it }
        if (widgets.isEmpty() || bad.isNotEmpty())
            throw GradleException("R8 renamed or merged home screen widget classes (keep them in proguard-rules.pro): ${bad.ifEmpty { listOf("none found") }}")
    }
}
