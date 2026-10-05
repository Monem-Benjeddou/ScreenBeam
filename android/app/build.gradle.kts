plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.screenbeam.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.screenbeam.app"
        minSdk = 26
        targetSdk = 35
        // CI passes these from the release tag (v1.2 -> versionName 1.2, versionCode = run number).
        versionCode = (System.getenv("VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("VERSION_NAME") ?: "1.0"
    }

    // Release key from the environment (CI secrets, or a local export). Without it, release builds
    // fall back to the debug key so anyone can build an installable APK.
    val releaseKeystore = System.getenv("ANDROID_KEYSTORE_PATH")?.let { file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "screenbeam"
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Google's QR scanner UI from Play services: no camera permission or scanner code in this app.
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
}
