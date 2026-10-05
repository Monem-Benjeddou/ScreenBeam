package com.screenbeam.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.Inet4Address

/** Finds Macs running ScreenBeam on the local network via Bonjour (mDNS / DNS-SD). */
class Discovery(context: Context, private val onChange: (List<Host>) -> Unit) {
    data class Host(val name: String, val address: String, val port: Int)

    private val nsd = context.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val hosts = LinkedHashMap<String, Host>()
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        if (listener != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "discovery failed: $errorCode")
                main.post { if (listener === this) listener = null }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                main.post { pending.addLast(info); resolveNext() }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                main.post { if (hosts.remove(info.serviceName) != null) publish() }
            }
        }
        listener = l
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            Log.w(TAG, "discoverServices failed", e)
            listener = null
        }
    }

    fun stop() {
        val l = listener ?: return
        listener = null
        try { nsd.stopServiceDiscovery(l) } catch (_: Exception) {}
        pending.clear()
        hosts.clear()
        publish()
    }

    // NsdManager can only resolve one service at a time on older Android versions.
    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving || listener == null) return
        val info = pending.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                main.post { resolving = false; resolveNext() }
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                val address = ipv4Of(info)
                main.post {
                    resolving = false
                    if (address != null && listener != null) {
                        hosts[info.serviceName] = Host(info.serviceName, address, info.port)
                        publish()
                    }
                    resolveNext()
                }
            }
        })
    }

    @Suppress("DEPRECATION")
    private fun ipv4Of(info: NsdServiceInfo): String? {
        val candidates = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
        return (candidates.firstOrNull { it is Inet4Address } ?: candidates.firstOrNull())?.hostAddress
    }

    private fun publish() = onChange(hosts.values.toList())

    companion object {
        private const val TAG = "ScreenBeam"
        private const val SERVICE_TYPE = "_screenbeam._tcp"
    }
}
