import java.util.Properties
import java.io.FileInputStream

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

        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        buildConfigField("String", "API_BASE_URL", "\"https://shop.jmsht.one\"")
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        debug {
            // 模拟器访问宿主机本地服务用 10.0.2.2（Android 模拟器的固定别名，
            // 指向开发机的 127.0.0.1），不是模拟器自己的 localhost。
            // 真机跑 debug 包连不到这个地址是正常的——真机需要用电脑的局域网 IP。
            // ⚠️ 端口按你本地后端实际监听的端口改一下（当前占位写的是 8000）。
            buildConfigField("String", "API_BASE_URL", "\"http://10.0.2.2:8000\"")

            // defaultConfig 里只打了 arm64-v8a，大部分电脑上跑的模拟器默认是
            // x86_64 架构（Apple Silicon Mac 上选 ARM 镜像的模拟器除外），
            // 装了 debug 包但原生库里没有对应架构的 .so，直接跑不起来。
            // 这里只给 debug 变体额外加上 x86_64/x86，release 仍然只打 arm64-v8a
            // （buildType 的 abiFilters 和 defaultConfig 是合并关系，不是覆盖）。
            ndk {
                abiFilters += listOf("x86_64", "x86")
            }
        }
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}