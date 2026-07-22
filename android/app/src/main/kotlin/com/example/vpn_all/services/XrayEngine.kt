package com.example.vpn_all

import android.content.Context
import android.util.Base64
import android.util.Log
import java.security.SecureRandom

import libv2ray.Libv2ray
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController

object XrayEngine {

    private var isRunning = false
    private var coreController: CoreController? = null

    fun isConnected(): Boolean = isRunning

    fun buildVlessConfig(
        address: String,
        port: Int,
        uuid: String,
        flow: String = "xtls-rprx-vision",
        encryption: String = "none",
        network: String = "tcp",
        security: String = "reality",
        realityPublicKey: String,
        realityShortId: String,
        realityServerName: String,
        realityFingerprint: String = "chrome",
        realitySpiderX: String = "/"
    ): String {
        return """
{
  "log": {
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "protocol": "tun",
      "tag": "tun-in",
      "settings": {
        "address": ["10.0.0.2/24", "fd00:1:1:1::2/64"],
        "mtu": 1500
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "proxy",
      "settings": {
        "vnext": [
          {
            "address": "$address",
            "port": $port,
            "users": [
              {
                "id": "$uuid",
                "encryption": "$encryption",
                "flow": "$flow"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$network",
        "security": "$security",
        "realitySettings": {
          "show": false,
          "fingerprint": "$realityFingerprint",
          "serverName": "$realityServerName",
          "publicKey": "$realityPublicKey",
          "shortId": "$realityShortId",
          "spiderX": "$realitySpiderX"
        }
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "proxy"
      }
    ]
  }
}
    """.trimIndent()
    }

    /**
     * 启动 Xray 核心。
     *
     * 【重要】这个函数本身是"发射后不管"的——真正的初始化在内部线程里跑，
     * 而且内部所有异常都会被自己 catch 掉，不会往外抛。所以调用方绝对不能
     * 靠"这个函数调用有没有抛异常"来判断连接是否成功！
     *
     * 正确做法：连接是否成功，以 onReady / onFailed 这两个回调为准：
     *   - onReady：核心真正回调了 startup()，说明核心已经跑起来了
     *   - onFailed：初始化过程中出异常，或者 startLoop 返回后核心一直没
     *     确认启动（说明大概率没连上）
     *
     * 回调会在后台线程触发，调用方如果要更新 UI / 发广播，记得自己切回主线程。
     */
    fun start(
        context: Context,
        tunFd: Int,
        configJson: String,
        onReady: () -> Unit,
        onFailed: (String) -> Unit
    ) {
        if (isRunning) {
            Log.d("XrayEngine", "引擎已在运行中，忽略重复启动")
            return
        }

        Thread {
            try {
                Log.d("XrayEngine", "正在初始化 Xray 核心环境...")
                Log.d("XrayEngine", "TUN FD: $tunFd")

                val envPath = context.filesDir.absolutePath
                Log.d("XrayEngine", "环境路径: $envPath")

                val keyBytes = ByteArray(32)
                SecureRandom().nextBytes(keyBytes)
                val xudpKey = Base64.encodeToString(
                    keyBytes,
                    Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
                )
                Log.d("XrayEngine", "生成的XUDP Key: $xudpKey")

                Libv2ray.initCoreEnv(envPath, xudpKey)
                Log.d("XrayEngine", "核心环境初始化完成")

                val callback = object : CoreCallbackHandler {
                    override fun onEmitStatus(p0: Long, p1: String?): Long {
                        Log.d("XrayEngine", "核心状态回调: $p1")
                        return 0L
                    }
                    override fun shutdown(): Long {
                        Log.d("XrayEngine", "核心已关闭")
                        isRunning = false
                        return 0L
                    }
                    override fun startup(): Long {
                        Log.d("XrayEngine", "✅ 核心已启动")
                        isRunning = true
                        onReady() // 真正启动成功才回调，通知外层
                        return 0L
                    }
                }

                coreController = Libv2ray.newCoreController(callback)
                Log.d("XrayEngine", "核心控制器创建成功，开始启动循环...")

                coreController?.startLoop(configJson, tunFd)

                // 兜底：极少数情况下 startLoop 正常返回但核心没有回调 startup()，
                // 稍等一下再确认一次，避免 App 永远卡在"连接中"却没人报错。
                Thread.sleep(800)
                if (!isRunning) {
                    Log.e("XrayEngine", "startLoop 返回后核心一直未确认启动，判定为失败")
                    onFailed("核心未确认启动，请检查节点配置或网络")
                }

            } catch (e: Exception) {
                Log.e("XrayEngine", "Xray 核心运行异常", e)
                isRunning = false
                coreController = null
                onFailed("${e.javaClass.simpleName}: ${e.message}")
            }
        }.start()
    }

    fun stop() {
        if (!isRunning && coreController == null) {
            Log.d("XrayEngine", "引擎未在运行，无需关闭")
            return
        }
        Log.d("XrayEngine", "🛑 正在关闭引擎...")

        try {
            coreController?.stopLoop()
        } catch (e: Exception) {
            Log.e("XrayEngine", "关闭引擎时出错", e)
        }

        coreController = null
        isRunning = false
        Log.d("XrayEngine", "引擎已彻底关闭。")
    }
}