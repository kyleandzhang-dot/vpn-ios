plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.vpn_all"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.example.vpn_all"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 统一在这里控制架构，debug/release 不再单独覆盖
        // 真机发布只需要 arm64-v8a；如需模拟器调试，临时加上 x86_64
        ndk {
            abiFilters += listOf("arm64-v8a")
            // 调试时如需模拟器支持，改成：
            // abiFilters += listOf("arm64-v8a", "x86_64")
        }

        buildConfigField("String", "API_BASE_URL", "\"https://shop.jmsht.one\"")
    }

    buildFeatures {
        buildConfig = true
    }

    // 不再需要 buildTypes 里的 ndk 块，删除即可
}

flutter {
    source = "../.."
}

dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}