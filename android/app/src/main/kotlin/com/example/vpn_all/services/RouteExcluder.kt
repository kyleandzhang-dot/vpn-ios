package com.example.vpn_all

import android.net.VpnService
import android.util.Log
import java.net.InetAddress
import java.nio.ByteBuffer

object RouteExcluder {

    private const val TOTAL_BITS = 32

    fun computeRoutesExcluding(excludeIp: String): List<Pair<String, Int>> {
        try {
            val excludeAddr = ipToInt(excludeIp)
            val result = mutableListOf<Pair<String, Int>>()

            var currentBase = 0
            var currentPrefix = 0

            while (currentPrefix < TOTAL_BITS) {
                val nextPrefix = currentPrefix + 1
                val half = 1 shl (TOTAL_BITS - nextPrefix)
                val lowerBase = currentBase
                val upperBase = currentBase or half

                val excludeInUpper = (excludeAddr and half) != 0

                if (excludeInUpper) {
                    // 低半区加入结果
                    val ip = intToIp(lowerBase)
                    // 检查是否是有效的网络地址
                    if (isValidNetworkAddress(lowerBase, nextPrefix)) {
                        result.add(Pair(ip, nextPrefix))
                    } else {
                        Log.w("RouteExcluder", "跳过无效网络地址: $ip/$nextPrefix")
                    }
                    currentBase = upperBase
                } else {
                    // 高半区加入结果
                    val ip = intToIp(upperBase)
                    if (isValidNetworkAddress(upperBase, nextPrefix)) {
                        result.add(Pair(ip, nextPrefix))
                    } else {
                        Log.w("RouteExcluder", "跳过无效网络地址: $ip/$nextPrefix")
                    }
                    currentBase = lowerBase
                }
                currentPrefix = nextPrefix
            }

            // 如果结果太少或者为空，使用备选方案
            if (result.size < 10) {
                Log.w("RouteExcluder", "生成的路由太少，使用备选方案")
                return getFallbackRoutes(excludeIp)
            }

            Log.d("RouteExcluder", "生成的有效路由数量: ${result.size}")
            result.forEach { Log.d("RouteExcluder", "有效路由: ${it.first}/${it.second}") }

            return result

        } catch (e: Exception) {
            Log.e("RouteExcluder", "计算路由失败", e)
            return getFallbackRoutes(excludeIp)
        }
    }

    private fun getFallbackRoutes(excludeIp: String): List<Pair<String, Int>> {
        // 备选方案：使用简单的路由覆盖
        return listOf(
            Pair("0.0.0.0", 1),
            Pair("128.0.0.0", 1)
        )
    }

    fun applyExcludingRoutes(builder: VpnService.Builder, excludeIp: String) {
        try {
            val routes = computeRoutesExcluding(excludeIp)
            var successCount = 0
            for ((network, prefix) in routes) {
                try {
                    builder.addRoute(network, prefix)
                    successCount++
                    Log.d("RouteExcluder", "成功添加路由: $network/$prefix")
                } catch (e: Exception) {
                    Log.e("RouteExcluder", "添加路由失败: $network/$prefix", e)
                    // 如果某个路由失败，尝试添加单个IP路由作为备选
                    if (prefix < 30) {
                        try {
                            // 尝试添加更小的路由
                            val parts = network.split(".")
                            if (parts.size == 4) {
                                val baseIp = "${parts[0]}.${parts[1]}.${parts[2]}.0"
                                builder.addRoute(baseIp, 24)
                                Log.d("RouteExcluder", "备选添加路由: $baseIp/24")
                            }
                        } catch (ex: Exception) {
                            Log.e("RouteExcluder", "备选路由也失败", ex)
                        }
                    }
                }
            }
            Log.d("RouteExcluder", "成功添加 $successCount/${routes.size} 条路由")
        } catch (e: Exception) {
            Log.e("RouteExcluder", "应用排除路由失败", e)
            // 如果排除路由失败，使用最基本的方案
            try {
                builder.addRoute("0.0.0.0", 1)
                builder.addRoute("128.0.0.0", 1)
                Log.w("RouteExcluder", "使用备选路由: 0.0.0.0/1 和 128.0.0.0/1")
            } catch (ex: Exception) {
                Log.e("RouteExcluder", "备选路由也失败", ex)
            }
        }
    }

    private fun isValidNetworkAddress(ipInt: Int, prefix: Int): Boolean {
        if (prefix == 0) return true
        if (prefix == 32) return true

        // 检查地址的后 (32 - prefix) 位是否为0
        val mask = if (prefix == 0) 0 else (0xFFFFFFFF.toInt() shl (32 - prefix))
        return (ipInt and mask) == ipInt
    }

    private fun ipToInt(ip: String): Int {
        try {
            val address = InetAddress.getByName(ip)
            val bytes = address.address
            if (bytes.size != 4) {
                throw IllegalArgumentException("不是IPv4地址: $ip")
            }
            return ByteBuffer.wrap(bytes).int
        } catch (e: Exception) {
            Log.e("RouteExcluder", "IP转换失败: $ip", e)
            throw e
        }
    }

    private fun intToIp(value: Int): String {
        try {
            val buffer = ByteBuffer.allocate(4)
            buffer.putInt(value)
            return InetAddress.getByAddress(buffer.array()).hostAddress ?: "0.0.0.0"
        } catch (e: Exception) {
            Log.e("RouteExcluder", "Int转IP失败: $value", e)
            return "0.0.0.0"
        }
    }
}