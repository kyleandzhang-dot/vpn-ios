package com.example.vpn_all

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import com.example.vpn_all.BuildConfig
import com.example.vpn_all.MainActivity
import com.example.vpn_all.R
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL

class CustomVpnService : VpnService() {

    private val CHANNEL_ID = "CustomVpnChannel"
    private val NOTIFICATION_ID = 1001

    // 到期提醒专用 channel（必须单独开一个，且重要级别要 HIGH，才能弹横幅/响铃，
    // 复用常驻的 CHANNEL_ID 的话默认级别通常是 DEFAULT/LOW，静默出现在通知栏用户很容易忽略）
    private val EXPIRED_CHANNEL_ID = "CustomVpnExpiredChannel"
    private val EXPIRED_NOTIFICATION_ID = 1002

    // 意外断线提醒专用 channel/id：跟"到期"复用同一套高优先级 channel 的思路，
    // 但文案区分开，因为这俩是不同原因导致的断开。
    private val ALERT_NOTIFICATION_ID = 1003

    private var vpnInterface: ParcelFileDescriptor? = null
    private var serverAddress: String = ""

    // 是否正在建立连接（从收到 ACTION_CONNECT 到 XrayEngine 回调 onReady/onFailed 之间）。
    // 用来防止用户连续点击时重入，同时保证一次失败之后能正确复位，
    // 不会出现"点了没反应，永远卡在触发连接"的情况。
    @Volatile private var isConnecting = false

    // 是否曾经真正连接成功过（即收到过 XrayEngine 的 onReady 回调）。
    // 用来区分"从未连上就失败了"（App一般在前台，Toast 提示就够）
    // 和"连上了后来又意外断开"（这种要弹通知，尤其是App在后台时，
    // 不然常驻通知栏还显示"正在为您提供安全连接"，用户会误以为自己还在被保护）。
    @Volatile private var wasConnected = false

    // 心跳逻辑
    private val handler = Handler(Looper.getMainLooper())
    private val checkRunnable = object : Runnable {
        override fun run() {
            checkUserStatus()
            handler.postDelayed(this, 60000) // 每 60 秒检查一次
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        when (action) {
            "ACTION_CONNECT" -> {
                val nodeJson = intent.getStringExtra("NODE_CONFIG_JSON")
                if (nodeJson.isNullOrEmpty()) {
                    Log.e("CustomVpnService", "缺少节点配置，无法连接")
                    stopSelf()
                    return START_NOT_STICKY
                }

                if (isConnecting) {
                    // 上一次连接还在进行中（还没等到 onReady/onFailed），忽略这次重复点击，
                    // 不然会重复 establish() TUN 接口，状态会更乱。
                    Log.w("CustomVpnService", "上一次连接尚未完成，忽略本次重复的连接指令")
                    return START_STICKY
                }

                if (vpnInterface != null) {
                    // 上一次连接没有走完整的 stopVpn() 流程就留下了残留的 TUN 接口
                    // （比如之前那个"没有真正确认成功也没有真正失败"的BUG造成的）。
                    // 这里先彻底清理掉，再重新走一遍连接流程，否则 establish() 可能会失败，
                    // 表现出来就是"怎么点都没反应"。
                    Log.w("CustomVpnService", "检测到残留的VPN连接状态，先清理再重连")
                    forceCleanupStaleState()
                }

                Log.d("CustomVpnService", "收到连接指令")
                isConnecting = true

                createNotificationChannel()
                startForeground(NOTIFICATION_ID, createNotification())

                // 启动心跳检查
                handler.post(checkRunnable)

                startVpn(nodeJson)
            }
            "ACTION_DISCONNECT" -> {
                Log.d("CustomVpnService", "收到断开连接指令")
                stopVpn(expired = false, userInitiated = true) // 用户主动断开
            }
        }
        return START_STICKY
    }

    // ================= 【核心修复一】：心跳强制绕过 VPN =================
    private fun checkUserStatus() {
        Thread {
            try {
                // 跟随 build variant 自动切换：debug 用本地局域网地址，release 用正式服务器
                // 之前这里硬编码了 https://vpn.freedreamky.com，导致 debug 包测试时
                // 心跳一直打到正式服务器（该设备在正式库里不存在，返回 404 而非 403，
                // 心跳代码只处理了 403，所以本地服务器怎么改过期时间都没反应）
                val url = URL("${BuildConfig.API_BASE_URL}/api/v1/check_status")

                // 1. 获取系统的网络连接管理器
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                var physicalNetwork: Network? = null

                // 2. 遍历当前所有网络，找出一个【有网且不是 VPN】的底层物理网络（WiFi或数据流量）
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    for (network in cm.allNetworks) {
                        val caps = cm.getNetworkCapabilities(network)
                        if (caps != null &&
                            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                            !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                            physicalNetwork = network
                            break
                        }
                    }
                }

                // 3. 强制使用物理网络建立连接，彻底绕过代理隧道！
                val conn = if (physicalNetwork != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    physicalNetwork.openConnection(url) as HttpURLConnection
                } else {
                    url.openConnection() as HttpURLConnection
                }

                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.doOutput = true
                conn.connectTimeout = 5000
                conn.readTimeout = 5000

                val json = JSONObject()
                json.put("device_id", android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.ANDROID_ID).uppercase())

                val writer = OutputStreamWriter(conn.outputStream)
                writer.write(json.toString())
                writer.flush()
                writer.close()

                if (conn.responseCode == 200) {
                    val resText = conn.inputStream.bufferedReader().readText()
                    Log.d("CustomVpnService", "心跳返回: $resText")
                    val res = JSONObject(resText)

                    getSharedPreferences("vpn_heartbeat", Context.MODE_PRIVATE)
                        .edit()
                        .putLong("last_heartbeat_attempt", System.currentTimeMillis())
                        .putString("last_heartbeat_error", "")
                        .apply()

                    if (res.getInt("code") == 403) {
                        Log.d("CustomVpnService", "检测到过期，强制断开！")
                        handler.post {
                            showExpiredNotification()
                            stopVpn(expired = true)
                        }
                    } else if (res.getInt("code") != 200) {
                        // 非 200 非 403 的其他返回码（比如 404 用户不存在）打日志留痕，
                        // 之前就是因为这里没打印，静默吃掉了错误地址导致的 404，排查了半天
                        Log.w("CustomVpnService", "心跳返回异常code: ${res.getInt("code")}, msg=${res.optString("msg")}")
                    }
                } else {
                    Log.e("CustomVpnService", "心跳请求失败，状态码: ${conn.responseCode}")
                }
            } catch (e: Exception) {
                // 打印更具体的异常类型，方便区分是 SNI/TLS 握手失败、超时、还是 DNS 解析失败
                Log.e("CustomVpnService", "心跳检查异常: ${e.javaClass.name} - ${e.message}", e)
                // 记录最后一次心跳尝试时间，配合 MainActivity 可以判断心跳循环是否还活着
                getSharedPreferences("vpn_heartbeat", Context.MODE_PRIVATE)
                    .edit()
                    .putLong("last_heartbeat_attempt", System.currentTimeMillis())
                    .putString("last_heartbeat_error", "${e.javaClass.simpleName}: ${e.message}")
                    .apply()
            }
        }.start()
    }

    private fun startVpn(nodeJson: String) {
        try {
            val json = JSONObject(nodeJson)
            val address = json.getString("address")
            val port = json.getInt("port")
            val uuid = json.getString("uuid")
            val flow = json.optString("flow", "xtls-rprx-vision")
            val encryption = json.optString("encryption", "none")
            val network = json.optString("network", "tcp")
            val security = json.optString("security", "reality")

            val reality = json.getJSONObject("reality")
            val publicKey = reality.getString("publicKey")
            val shortId = reality.getString("shortId")
            val serverName = reality.getString("serverName")
            val fingerprint = reality.optString("fingerprint", "chrome")
            val spiderX = reality.optString("spiderX", "/")

            serverAddress = address

            val builder = Builder()
                .setSession("MyVlessVpn")
                .addAddress("10.0.0.2", 24)
                .addDnsServer("8.8.8.8")
                .addDnsServer("1.1.1.1")
                .setMtu(1500)
                .setBlocking(true)

            Log.d("CustomVpnService", "正在通过 RouteExcluder 排除服务器 IP: $address")
            RouteExcluder.applyExcludingRoutes(builder, address)

            vpnInterface = builder.establish()
            val fd = vpnInterface?.fd

            if (fd == null) {
                Log.e("CustomVpnService", "❌ 获取TUN FD失败！")
                isConnecting = false
                stopVpn(expired = false, errorMessage = "获取TUN设备失败")
                return
            }

            Log.d("CustomVpnService", "✅ TUN设备建立成功，FD: $fd")

            val configJson = XrayEngine.buildVlessConfig(
                address = address, port = port, uuid = uuid, flow = flow,
                encryption = encryption, network = network, security = security,
                realityPublicKey = publicKey, realityShortId = shortId,
                realityServerName = serverName, realityFingerprint = fingerprint,
                realitySpiderX = spiderX
            )

            // 【核心修复】：不再假定"调用没报错=连接成功"。
            // XrayEngine.start() 本身立刻就会返回（它只是起了个后台线程），
            // 真正连没连上，以 onReady / onFailed 这两个回调为准。
            XrayEngine.start(
                context = this,
                tunFd = fd,
                configJson = configJson,
                onReady = {
                    // 这里是核心真正回调 startup() 之后才会走到，说明是真的连上了
                    handler.post {
                        isConnecting = false
                        wasConnected = true
                        Log.d("CustomVpnService", "🚀 核心确认启动成功，通知 Dart 侧")
                        val connectedIntent = Intent("com.example.vpn_all.ACTION_VPN_CONNECTED")
                        connectedIntent.setPackage(packageName)
                        sendBroadcast(connectedIntent)
                        testConnectivity()
                    }
                },
                onFailed = { reason ->
                    handler.post {
                        isConnecting = false
                        Log.e("CustomVpnService", "Xray引擎启动失败: $reason")
                        stopVpn(expired = false, errorMessage = "Xray启动失败: $reason")
                    }
                }
            )
        } catch (e: Exception) {
            Log.e("CustomVpnService", "❌ 建立VPN失败", e)
            isConnecting = false
            val detail = "建立VPN失败: ${e.javaClass.simpleName}: ${e.message}"
            stopVpn(expired = false, errorMessage = detail)
        }
    }

    /**
     * 只清理本地残留资源（不发广播、不 stopSelf），用于"重连前先扫一遍尾"的场景，
     * 避免上次遗留的 TUN 接口 / 核心状态挡住这一次的新连接。
     */
    private fun forceCleanupStaleState() {
        try {
            XrayEngine.stop()
            vpnInterface?.close()
        } catch (e: Exception) {
            Log.e("CustomVpnService", "清理残留连接状态异常", e)
        } finally {
            vpnInterface = null
        }
    }

    private fun testConnectivity() {
        Thread {
            try {
                try {
                    val address = InetAddress.getByName("www.google.com")
                    Log.d("CustomVpnService", "✅ DNS解析成功: www.google.com -> ${address.hostAddress}")
                } catch (e: Exception) { Log.e("CustomVpnService", "❌ DNS解析失败", e) }

                try {
                    val process = Runtime.getRuntime().exec("ping -c 1 -W 2 8.8.8.8")
                    if (process.waitFor() == 0) Log.d("CustomVpnService", "✅ Ping 8.8.8.8 成功")
                    else Log.e("CustomVpnService", "❌ Ping 8.8.8.8 失败")
                } catch (e: Exception) { Log.e("CustomVpnService", "Ping执行失败", e) }
            } catch (e: Exception) { Log.e("CustomVpnService", "网络测试异常", e) }
        }.start()
    }

    // ================= 【核心修复二】：给广播加上包名 =================
    // errorMessage: 如果是因为异常导致的断开（非用户主动点击断开、非到期），带上具体原因方便排查
    // userInitiated: 是否是用户自己点了断开按钮——只有这种情况和"到期"不需要额外弹通知提醒，
    //                因为用户自己知道发生了什么/到期已经有专门的通知了
    private fun stopVpn(expired: Boolean = false, errorMessage: String? = null, userInitiated: Boolean = false) {
        handler.removeCallbacks(checkRunnable) // 停止心跳
        isConnecting = false

        // 只有"曾经真的连上过，现在又断了，且不是用户主动断开、也不是到期"这种
        // 情况才提醒——避免每次"从一开始就没连上"（比如节点不通）都弹通知打扰用户，
        // 那种场景 App 基本都在前台，Toast 已经够用了。
        val shouldAlertUnexpectedDrop = wasConnected && !expired && !userInitiated
        wasConnected = false

        try {
            XrayEngine.stop()
            vpnInterface?.close()
            vpnInterface = null
            Log.d("CustomVpnService", "VPN已关闭")
        } catch (e: Exception) {
            Log.e("CustomVpnService", "关闭VPN异常", e)
        }

        if (shouldAlertUnexpectedDrop) {
            showConnectionLostNotification(errorMessage)
        }

        // 发送广播通知 MainActivity (加上 setPackage 确保广播不会被系统抛弃)
        val intent = Intent("com.example.vpn_all.ACTION_VPN_DISCONNECTED")
        intent.setPackage(packageName) // <--- 关键！锁定当前应用包名
        intent.putExtra("is_expired", expired)
        if (!errorMessage.isNullOrEmpty()) {
            intent.putExtra("error_message", errorMessage)
        }
        sendBroadcast(intent)

        stopForeground(true)
        stopSelf()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "VPN 运行状态",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(serviceChannel)

            // 到期提醒 channel，IMPORTANCE_HIGH 才会有横幅+响铃提示，用户在后台也能看到
            val expiredChannel = NotificationChannel(
                EXPIRED_CHANNEL_ID,
                "到期提醒",
                NotificationManager.IMPORTANCE_HIGH
            )
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(expiredChannel)
        }
    }

    // 弹出"服务已到期"的系统通知。无论 App 是否在前台/后台，只要本 Service 还活着就能收到。
    private fun showExpiredNotification() {
        // 点击通知直接打开 MainActivity，并带上标记，方便 App 内弹出续费弹窗
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("FROM_EXPIRED_NOTIFICATION", true)
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 1, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = NotificationCompat.Builder(this, EXPIRED_CHANNEL_ID)
            .setContentTitle("服务已到期")
            .setContentText("您的加速服务已过期，已为您断开连接，点击立即续费")
            .setSmallIcon(R.drawable.ic_notification_expired)
            .setLargeIcon(android.graphics.BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        getSystemService(NotificationManager::class.java)
            ?.notify(EXPIRED_NOTIFICATION_ID, notification)
    }

    // 弹出"连接意外断开"的系统通知。只在"曾经连上过、现在又断了"且不是用户
    // 主动点断开、也不是到期的情况下调用（见 stopVpn 里的判断）。
    // 场景例子：核心崩了、被服务器踢了、切换 Wi-Fi/流量导致隧道断开——
    // 这些如果发生在App后台，用户完全无感知，但常驻通知栏之前一直显示
    // "正在为您提供安全连接..."，不弹一个提醒的话用户会一直以为自己还在被保护。
    private fun showConnectionLostNotification(reason: String?) {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 2, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = NotificationCompat.Builder(this, EXPIRED_CHANNEL_ID)
            .setContentTitle("连接已断开")
            .setContentText("您的安全连接意外中断，请重新点击连接")
            .setSmallIcon(R.drawable.ic_notification_expired)
            .setLargeIcon(android.graphics.BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        getSystemService(NotificationManager::class.java)
            ?.notify(ALERT_NOTIFICATION_ID, notification)
    }

    private fun createNotification(): Notification {
        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("秒连 VPN")
            .setContentText("正在为您提供安全连接...")
            .setSmallIcon(android.R.drawable.ic_secure)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        stopVpn(expired = false)
        super.onDestroy()
    }
}