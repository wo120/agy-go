plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val harmonyCompat = (project.findProperty("harmonyCompat") as String?)?.toBoolean() == true

android {
    namespace = "com.antigravity.mobile"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.antigravity.mobile"
        minSdk = 26
        targetSdk = if (harmonyCompat) 34 else 35
        versionCode = 1
        versionName = "0.1.0"
        manifestPlaceholders["enableImpeller"] = if (harmonyCompat) "false" else "true"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
}

flutter {
    source = "../.."
}
