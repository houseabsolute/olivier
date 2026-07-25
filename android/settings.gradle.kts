pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Pinned to AGP 8.x, not the template's 9.x, because two dependencies
    // disagree under AGP 9: audio_service 0.18.18 applies kotlin-android
    // unconditionally (AGP 9 rejects that unless android.builtInKotlin=false),
    // while file_picker 11.0.2 detects AGP 9 and skips applying KGP, expecting
    // built-in Kotlin to compile it (which needs builtInKotlin=true). On AGP 8
    // both plugins apply their own KGP and agree. Revisit when audio_service
    // migrates to built-in Kotlin.
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
