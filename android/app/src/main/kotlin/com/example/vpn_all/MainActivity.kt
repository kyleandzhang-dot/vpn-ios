package com.example.vpn_all

import android.app.Activity
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // ================= VPN 相关（原有，未改动） =================
    private val METHOD_CHANNEL = "com.example.vpn_all/vpn"
    private val EVENT_CHANNEL = "com.example.vpn_all/vpn_status"
    private val VPN_REQUEST_CODE = 1001

    private var pendingNodeJson: String? = null
    private var eventSink: EventChannel.EventSink? = null

    private val vpnStatusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                "com.example.vpn_all.ACTION_VPN_CONNECTED" -> {
                    eventSink?.success("CONNECTED")
                }
                "com.example.vpn_all.ACTION_VPN_DISCONNECTED" -> {
                    val expired = intent.getBooleanExtra("is_expired", false)
                    val errorMessage = intent.getStringExtra("error_message")
                    if (!errorMessage.isNullOrEmpty()) {
                        eventSink?.error("VPN_ERROR", errorMessage, null)
                    } else if (expired) {
                        eventSink?.success("EXPIRED")
                    } else {
                        eventSink?.success("DISCONNECTED")
                    }
                }
            }
        }
    }

    // ================= 商城下载相关（新增） =================
    private val MARKET_CHANNEL = "com.example.vpn_all/market"
    private val UTILS_CHANNEL = "com.example.vpn_all/utils"
    private val REQUEST_INSTALL_PERMISSION_CODE = 2001

    private lateinit var downloadManager: DownloadManager
    private lateinit var marketPrefs: SharedPreferences
    private var pendingInstallPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        downloadManager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        marketPrefs = getSharedPreferences("market_downloads", Context.MODE_PRIVATE)

        // ---------- VPN MethodChannel ----------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connect" -> {
                        val nodeJson = call.argument<String>("node_json")
                        if (nodeJson.isNullOrEmpty()) {
                            result.error("INVALID_ARGUMENT", "缺少节点配置", null)
                            return@setMethodCallHandler
                        }
                        startVpnFlow(nodeJson)
                        result.success(null)
                    }
                    "disconnect" -> {
                        val intent = Intent(this, CustomVpnService::class.java).apply {
                            action = "ACTION_DISCONNECT"
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "getCurrentState" -> {
                        result.success(if (XrayEngine.isConnected()) "CONNECTED" else "DISCONNECTED")
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        // ---------- 商城 MethodChannel ----------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MARKET_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isPackageInstalled" -> {
                        val packageName = call.argument<String>("package_name") ?: ""
                        result.success(isPackageInstalled(packageName))
                    }
                    "canInstallUnknownApps" -> {
                        result.success(canInstallUnknownApps())
                    }
                    "requestInstallPermission" -> {
                        pendingInstallPermissionResult = result
                        val intent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")
                        )
                        try {
                            startActivityForResult(intent, REQUEST_INSTALL_PERMISSION_CODE)
                        } catch (e: Exception) {
                            pendingInstallPermissionResult = null
                            result.success(canInstallUnknownApps())
                        }
                    }
                    "startDownload" -> {
                        try {
                            val appId = call.argument<String>("app_id")!!
                            val apkUrl = call.argument<String>("apk_url")!!
                            val appName = call.argument<String>("app_name") ?: appId
                            val version = call.argument<String>("version") ?: ""

                            val request = DownloadManager.Request(Uri.parse(apkUrl))
                                .setTitle(appName)
                                .setDescription("正在下载 $appName")
                                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                                .setDestinationInExternalFilesDir(
                                    this, Environment.DIRECTORY_DOWNLOADS, "${appId}_${version}.apk"
                                )
                                .setAllowedOverMetered(true)
                                .setAllowedOverRoaming(true)

                            val downloadId = downloadManager.enqueue(request)
                            marketPrefs.edit().putLong(appId, downloadId).apply()
                            result.success(downloadId.toString())
                        } catch (e: Exception) {
                            result.error("DOWNLOAD_FAILED", e.message, null)
                        }
                    }
                    "queryDownloadStatus" -> {
                        val downloadId = call.argument<String>("download_id")?.toLongOrNull()
                        if (downloadId == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        val status = queryDownloadStatus(downloadId)
                        if (status == null) {
                            result.success(null)
                        } else {
                            result.success(status)
                        }
                    }
                    "getSavedDownloadId" -> {
                        val appId = call.argument<String>("app_id") ?: ""
                        val id = marketPrefs.getLong(appId, -1L)
                        result.success(id.toString())
                    }
                    "removeSavedDownloadId" -> {
                        val appId = call.argument<String>("app_id") ?: ""
                        marketPrefs.edit().remove(appId).apply()
                        result.success(null)
                    }
                    "installDownloadedApk" -> {
                        val downloadId = call.argument<String>("download_id")?.toLongOrNull()
                        if (downloadId == null) {
                            result.error("INVALID_ARGUMENT", "缺少 download_id", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = downloadManager.getUriForDownloadedFile(downloadId)
                            if (uri != null) {
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                startActivity(intent)
                                result.success(true)
                            } else {
                                result.error("NO_FILE", "安装包文件不存在", null)
                            }
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                    "launchApp" -> {
                        val packageName = call.argument<String>("package_name") ?: ""
                        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                        if (launchIntent != null) {
                            startActivity(launchIntent)
                            result.success(true)
                        } else {
                            result.error("NOT_FOUND", "无法打开该应用", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ---------- 通用工具 MethodChannel（保存图片到相册） ----------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UTILS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImageToGallery" -> {
                        try {
                            val bytes = call.argument<ByteArray>("bytes")
                            val filename = call.argument<String>("filename") ?: "image_${System.currentTimeMillis()}.png"
                            if (bytes == null) {
                                result.error("INVALID_ARGUMENT", "缺少图片数据", null)
                                return@setMethodCallHandler
                            }
                            val ok = saveImageToGallery(bytes, filename)
                            result.success(ok)
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ================= 商城相关方法 =================

    private fun isPackageInstalled(packageName: String): Boolean {
        if (packageName.isEmpty()) return false
        return try {
            packageManager.getPackageInfo(packageName, 0)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun canInstallUnknownApps(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    /** 返回 map: status(String) / downloaded(Long) / total(Long)，查不到记录返回 null */
    private fun queryDownloadStatus(downloadId: Long): Map<String, Any>? {
        val query = DownloadManager.Query().setFilterById(downloadId)
        val cursor = downloadManager.query(query)
        if (!cursor.moveToFirst()) {
            cursor.close()
            return null
        }
        val statusInt = cursor.getInt(cursor.getColumnIndex(DownloadManager.COLUMN_STATUS))
        val downloaded = cursor.getLong(cursor.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
        val total = cursor.getLong(cursor.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
        cursor.close()

        val statusStr = when (statusInt) {
            DownloadManager.STATUS_SUCCESSFUL -> "SUCCESSFUL"
            DownloadManager.STATUS_FAILED -> "FAILED"
            DownloadManager.STATUS_PENDING -> "PENDING"
            DownloadManager.STATUS_PAUSED -> "PAUSED"
            DownloadManager.STATUS_RUNNING -> "RUNNING"
            else -> "UNKNOWN"
        }
        return mapOf("status" to statusStr, "downloaded" to downloaded, "total" to total)
    }

    /** 复用旧版 RechargeActivity 的相册保存逻辑，供 Flutter 保存收款二维码用 */
    private fun saveImageToGallery(bytes: ByteArray, filename: String): Boolean {
        val contentValues = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/png")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/秒连VPN")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val resolver = contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues) ?: return false

        resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: return false

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            contentValues.clear()
            contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, contentValues, null, null)
        }
        return true
    }

    // ================= VPN 相关方法（原有，未改动） =================

    private fun startVpnFlow(nodeJson: String) {
        pendingNodeJson = nodeJson
        val prepareIntent = VpnService.prepare(this)
        if (prepareIntent != null) {
            startActivityForResult(prepareIntent, VPN_REQUEST_CODE)
        } else {
            actuallyStartVpn(nodeJson)
        }
    }

    private fun actuallyStartVpn(nodeJson: String) {
        eventSink?.success("CONNECTING")
        val intent = Intent(this, CustomVpnService::class.java).apply {
            action = "ACTION_CONNECT"
            putExtra("NODE_CONFIG_JSON", nodeJson)
        }
        startService(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            VPN_REQUEST_CODE -> {
                if (resultCode == Activity.RESULT_OK) {
                    pendingNodeJson?.let { actuallyStartVpn(it) }
                } else {
                    eventSink?.error("VPN_PERMISSION_DENIED", "用户拒绝了 VPN 权限", null)
                }
                pendingNodeJson = null
            }
            REQUEST_INSTALL_PERMISSION_CODE -> {
                pendingInstallPermissionResult?.success(canInstallUnknownApps())
                pendingInstallPermissionResult = null
            }
        }
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter().apply {
            addAction("com.example.vpn_all.ACTION_VPN_CONNECTED")
            addAction("com.example.vpn_all.ACTION_VPN_DISCONNECTED")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(vpnStatusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(vpnStatusReceiver, filter)
        }
    }

    override fun onStop() {
        super.onStop()
        unregisterReceiver(vpnStatusReceiver)
    }
    // 注：VPN真实状态的兜底同步走 "getCurrentState" 方法（见上面VPN MethodChannel），
    // Dart侧在 didChangeAppLifecycleState(resumed) 时主动调用它，而不是这里单方面推送，
    // 避免打断正在进行中的"连接中/已到期"等状态。
}