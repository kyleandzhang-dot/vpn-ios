plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.vpn_all"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.example.vpn_all"
        // --- 移植要点 1：将最低 SDK 改为 26，以兼容你的底层 VPN 服务 ---
        minSdk = 26 
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // --- 移植要点 2：保留旧项目的 CPU 架构过滤，防止 Xray 引擎真机闪退 ---
       // --- 移植要点 2：保留旧项目的 CPU 架构过滤，防止 Xray 引擎真机闪退 ---
        // 【临时调试】加上 x86_64，让 Flutter 引擎能在 x86_64 模拟器上正常加载
        // 正式发布真机版本时，把 x86_64 去掉，改回只有 armeabi-v7a / arm64-v8a
        ndk {
            //abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
            abiFilters += listOf("arm64-v8a")
        }

        // 补充自定义 BuildConfig 字段：后端接口的基础地址（改成你实际的服务器地址）
        buildConfigField("String", "API_BASE_URL", "\"https://shop.jmsht.one\"")
    }

    // 开启 BuildConfig 类的自动生成（AGP 8+ 默认关闭，需要手动打开）
    buildFeatures {
        buildConfig = true
    }

    buildTypes {
         release {
            ndk {
                abiFilters += listOf("arm64-v8a")
            }
        }
        debug {
            ndk {
                abiFilters += listOf("arm64-v8a", "x86_64")
            }
        }
    }
}

flutter {
    source = "../.."
}

// --- 移植要点 3：让 Gradle 加载 libs 目录下的 Xray 内核等本地第三方包 ---
dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))
}