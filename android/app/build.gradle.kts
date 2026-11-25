import java.util.Properties
import java.io.FileInputStream
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取签名配置
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.vpn_all"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.example.vpn_all"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 双架构支持：
        // ARM64：安卓真实手机
        // x86_64：MuMu 等 Windows 安卓模拟器
        ndk {
            abiFilters += listOf(
                "arm64-v8a",
                "x86_64"
            )
        }

        buildConfigField(
            "String",
            "API_BASE_URL",
            "\"https://shop.jmsht.one\""
        )
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = rootProject.file(
                    keystoreProperties["storeFile"] as String
                )
                storePassword =
                    keystoreProperties["storePassword"] as String
                keyAlias =
                    keystoreProperties["keyAlias"] as String
                keyPassword =
                    keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        debug {
            // Debug 使用本地开发后端
            buildConfigField(
                "String",
                "API_BASE_URL",
                "\"http://10.0.2.2:8000\""
            )
        }

        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// Kotlin 2.2 起 kotlinOptions{} 已弃用，改用 compilerOptions
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(
        fileTree(
            mapOf(
                "dir" to "libs",
                "include" to listOf("*.aar", "*.jar")
            )
        )
    )

    coreLibraryDesugaring(
        "com.android.tools:desugar_jdk_libs:2.0.4"
    )
}