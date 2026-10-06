package com.screenbeam.app

import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue

/**
 * Connects to the Mac, decodes the stream onto [surface], and reconnects automatically
 * until [stop] is called or the Mac says not to. Listener callbacks run on the network thread.
 */
class StreamClient(
    private val host: String,
    private val port: Int,
    private val surface: Surface,
    private val deviceName: String,
    private val pairingCode: String,
    /** No video (Pad / Sound modes). */
    private val noVideo: Boolean,
    /** Ask the Mac for its sound. */
    private val wantsAudio: Boolean,
    /** Sound mode: the phone is just a speaker (shown that way on the Mac). */
    private val soundOnly: Boolean,
    /** Extend mode: the Mac adds a virtual display shaped like [screenSize] and streams that. */
    private val extendDisplay: Boolean,
    private val screenSize: Pair<Int, Int>,
    private val listener: Listener,
) {
    private val audio = AudioPlayer()

    var soundOn: Boolean
        get() = !audio.muted
        set(value) { audio.muted = !value }

    interface Listener {
        fun onConnecting(attempt: Int, lastError: String?)
        fun onStreaming()
        fun onVideoSize(width: Int, height: Int)
        fun onStats(stats: Stats)
        /** The session ended for good (Mac disconnected us, or another phone took over). */
        fun onStopped(message: String)
        /** The Mac wants a (correct) pairing code before it will stream. */
        fun onPairingRequired(message: String)
        /** Several connections in a row got no reply at all: the app should restart itself. */
        fun onStuck() {}
    }

    data class Stats(
        val fps: Int, val mbps: Double, val rttMs: Int,
        val latencyMs: Int, val targetMbps: Double, val skipped: Int,
        val audioBufferMs: Int,
    )

    @Volatile private var running = true
    @Volatile private var socket: Socket? = null
    /** Outgoing messages; one writer thread drains it so decoder/ping threads never block on the socket. */
    private val outbox = LinkedBlockingQueue<ByteArray>()
    @Volatile private var macLatencyMs = 0
    @Volatile private var macBitrateKbps = 0
    @Volatile private var macSkipped = 0
    private val thread = Thread(::run, "ScreenBeam-net")

    fun start() = thread.start()

    fun stop() {
        running = false
        try { socket?.close() } catch (_: IOException) {}
        thread.interrupt()
    }

    /** Messages received in the current session by type, for the end-of-session log line. */
    private val received = IntArray(32)

    private fun run() {
        var attempt = 0
        var lastError: String? = null
        var silentSessions = 0
        while (running) {
            listener.onConnecting(attempt, lastError)
            try {
                val stop = session()
                if (stop != null) {
                    running = false
                    if (stop.pairing) listener.onPairingRequired(stop.message) else listener.onStopped(stop.message)
                    return
                }
                lastError = "Connection lost"
                attempt = 0
            } catch (e: ServerError) {
                lastError = e.message
            } catch (e: Exception) {
                if (!running) return
                Log.w(TAG, "session ended", e)
                lastError = friendly(e)
                // Connected, but nothing but "ready" came back (no pongs, no frames). Seen once after
                // another device took over: only restarting the app recovered, so do that ourselves.
                val replies = received.sum() - received[MSG_READY]
                if (e is java.net.SocketTimeoutException && replies == 0) {
                    if (++silentSessions >= 2) {
                        Log.w(TAG, "no reply in $silentSessions sessions in a row: asking the app to restart")
                        running = false
                        listener.onStuck()
                        return
                    }
                } else {
                    silentSessions = 0
                }
            }
            attempt++
            try { Thread.sleep(if (attempt < 3) 700L else 2000L) } catch (_: InterruptedException) { return }
        }
    }

    private class Stop(val message: String, val pairing: Boolean)

    /** Runs one connection. Returns non-null if the Mac asked us not to reconnect. */
    private fun session(): Stop? {
        val s = Socket()
        socket = s
        outbox.clear()
        received.fill(0)
        val startedAt = System.nanoTime()
        var lastMessageAt = startedAt
        val decoder = VideoDecoder(surface, ::sendKeyframeRequest, ::sendAck)
        var pinger: Thread? = null
        var writer: Thread? = null
        try {
            s.tcpNoDelay = true
            s.trafficClass = 0xB8 // DSCP EF: Wi-Fi gives these packets the low-latency (voice) queue
            s.connect(InetSocketAddress(host, port), 4000)
            s.soTimeout = 8000 // pongs arrive every second, so silence means a dead link
            if (!running) return null

            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 256 * 1024))
            val output = DataOutputStream(BufferedOutputStream(s.getOutputStream()))
            writer = Thread({ writeLoop(output, s) }, "ScreenBeam-write").apply { start() }
            sendHello()
            pinger = Thread({ pingLoop() }, "ScreenBeam-ping").apply { start() }

            var buffer = ByteArray(1024 * 1024)
            var bytes = 0L
            var lastStatsAt = System.nanoTime()
            var lastFrames = 0
            var streaming = false

            while (running) {
                val type = input.readUnsignedByte()
                val length = input.readInt()
                if (length < 0 || length > MAX_MESSAGE) throw IOException("Bad message length $length")
                if (length > buffer.size) buffer = ByteArray(length + length / 2)
                input.readFully(buffer, 0, length)
                bytes += length + 5
                if (type < received.size) received[type]++
                lastMessageAt = System.nanoTime()

                when (type) {
                    MSG_CONFIG -> {
                        val cfg = parseConfig(buffer, length)
                        if (decoder.configure(buffer.copyOf(length), cfg.mime, cfg.width, cfg.height, cfg.paramSets)) {
                            listener.onVideoSize(cfg.width, cfg.height)
                        }
                    }
                    MSG_FRAME -> {
                        if (length < 9) continue
                        val isKey = (buffer[0].toInt() and 1) != 0
                        val pts = ByteBuffer.wrap(buffer, 1, 8).long
                        decoder.decode(buffer, 9, length - 9, isKey, pts)
                        if (!streaming && isKey) {
                            streaming = true
                            listener.onStreaming()
                        }
                    }
                    MSG_PONG -> if (length >= 8) {
                        val sent = ByteBuffer.wrap(buffer, 0, 8).long
                        rttMs = ((System.nanoTime() - sent) / 1_000_000).toInt()
                    }
                    MSG_READY -> {
                        if (noVideo && !streaming) {
                            streaming = true
                            listener.onStreaming()
                        }
                        if (wantsAudio) audioChannel = Thread({ audioLoop() }, "ScreenBeam-audio-net").apply { start() }
                    }
                    MSG_AUDIO -> if (length > 8) audio.write(48_000, buffer, 8, length - 8)
                    MSG_AUDIO_LOW_LATENCY -> if (length > 4) {
                        audio.write(ByteBuffer.wrap(buffer, 0, 4).int, buffer, 4, length - 4)
                    }
                    MSG_STATS -> if (length >= 10) {
                        val bb = ByteBuffer.wrap(buffer, 0, length)
                        macLatencyMs = bb.short.toInt() and 0xffff
                        macBitrateKbps = bb.int
                        bb.short
                        macSkipped = bb.short.toInt() and 0xffff
                    }
                    MSG_ERROR -> {
                        val code = if (length > 0) buffer[0].toInt() else 1
                        val message = if (length > 1) String(buffer, 1, length - 1, Charsets.UTF_8) else "Error"
                        if (code == 2 || code == 3) return Stop(message, pairing = code == 3)
                        throw ServerError(message)
                    }
                }

                val now = System.nanoTime()
                if (now - lastStatsAt >= 1_000_000_000L) {
                    val frames = decoder.framesRendered.get()
                    val seconds = (now - lastStatsAt) / 1e9
                    listener.onStats(Stats(
                        fps = ((frames - lastFrames) / seconds).toInt(),
                        mbps = bytes * 8 / seconds / 1e6,
                        rttMs = rttMs,
                        latencyMs = macLatencyMs,
                        targetMbps = macBitrateKbps / 1000.0,
                        skipped = macSkipped,
                        audioBufferMs = audio.currentTargetMs,
                    ))
                    lastFrames = frames
                    if (decoder.maxInputWaitMs > 5) Log.i(TAG, "decoder input wait max ${decoder.maxInputWaitMs} ms")
                    decoder.maxInputWaitMs = 0
                    bytes = 0
                    lastStatsAt = now
                }
            }
            return null
        } finally {
            val counts = received.withIndex().filter { it.value > 0 }.joinToString { "${it.index}:${it.value}" }
            Log.i(TAG, "session summary: ${(System.nanoTime() - startedAt) / 1_000_000} ms, " +
                "last message ${(System.nanoTime() - lastMessageAt) / 1_000_000} ms ago, writer alive=${writer?.isAlive}, " +
                "outbox=${outbox.size}, received {$counts}")
            pinger?.interrupt()
            writer?.interrupt()
            audioChannel?.interrupt()
            try { audioSocket?.close() } catch (_: IOException) {}
            audioChannel = null
            try { s.close() } catch (_: IOException) {}
            decoder.release()
            audio.release()
        }
    }

    @Volatile private var rttMs = 0
    @Volatile private var audioSocket: Socket? = null
    private var audioChannel: Thread? = null

    /**
     * Second TCP connection that carries only audio. On the shared connection each 5 ms audio packet
     * could wait behind a whole video frame, and behind the video decoder on the reader thread.
     */
    private fun audioLoop() {
        // Receiving audio is real-time work: don't let the scheduler park this thread behind UI/video.
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
        val s = Socket()
        audioSocket = s
        try {
            s.tcpNoDelay = true
            s.trafficClass = 0xB8
            s.connect(InetSocketAddress(host, port), 3000)
            s.soTimeout = 10_000
            val out = DataOutputStream(BufferedOutputStream(s.getOutputStream()))
            val pin = pairingCode.toByteArray(Charsets.UTF_8)
            val hello = ByteBuffer.allocate(4 + 1 + pin.size).put("SBA1".toByteArray(Charsets.US_ASCII))
                .put(pin.size.toByte()).put(pin).array()
            out.writeByte(MSG_AUDIO_HELLO); out.writeInt(hello.size); out.write(hello); out.flush()
            // Every 250 ms: report our playout delay (the Mac delays its speakers to match), which also
            // keeps the channel alive; the Mac otherwise only ever sends on it.
            val keepAlive = Thread({
                try {
                    while (!Thread.currentThread().isInterrupted) {
                        Thread.sleep(250)
                        val ms = audio.playoutLatencyMs()
                        synchronized(out) {
                            if (ms != null) {
                                out.writeByte(MSG_AUDIO_LATENCY); out.writeInt(2); out.writeShort(ms.coerceIn(0, 65535))
                            } else {
                                out.writeByte(MSG_PING); out.writeInt(8); out.writeLong(0)
                            }
                            out.flush()
                        }
                    }
                } catch (_: Exception) {}
            }, "ScreenBeam-audio-ping").apply { isDaemon = true; start() }
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 64 * 1024))
            var buf = ByteArray(64 * 1024)
            try {
                while (running && !Thread.currentThread().isInterrupted) {
                    val type = input.readUnsignedByte()
                    val length = input.readInt()
                    if (length < 0 || length > 1 shl 20) break
                    if (length > buf.size) buf = ByteArray(length)
                    input.readFully(buf, 0, length)
                    when (type) {
                        MSG_AUDIO_LOW_LATENCY -> if (length > 4) audio.write(ByteBuffer.wrap(buf, 0, 4).int, buf, 4, length - 4)
                        MSG_AUDIO -> if (length > 8) audio.write(48_000, buf, 8, length - 8)
                    }
                }
            } finally {
                keepAlive.interrupt()
            }
        } catch (e: Exception) {
            Log.i(TAG, "audio channel closed: ${e.message}")
        } finally {
            try { s.close() } catch (_: IOException) {}
        }
    }

    private fun pingLoop() {
        try {
            while (running && !Thread.currentThread().isInterrupted) {
                send(MSG_PING, ByteBuffer.allocate(8).putLong(System.nanoTime()).array())
                Thread.sleep(1000)
            }
        } catch (_: InterruptedException) {
        }
    }

    private fun writeLoop(out: DataOutputStream, own: Socket) {
        try {
            while (running) {
                val msg = outbox.take()
                out.write(msg)
                // Coalesce whatever else is queued into the same flush.
                while (true) out.write(outbox.poll() ?: break)
                out.flush()
            }
        } catch (_: InterruptedException) {
        } catch (_: IOException) {
            try { own.close() } catch (_: IOException) {} // unblock this session's reader so we reconnect
        }
    }

    private fun sendHello() {
        val caps = VideoDecoder.capabilities()
        val name = deviceName.toByteArray(Charsets.UTF_8).let { if (it.size > 200) it.copyOf(200) else it }
        val pin = pairingCode.toByteArray(Charsets.UTF_8).let { if (it.size > 32) it.copyOf(32) else it }
        val payload = ByteBuffer.allocate(4 + 1 + 1 + 4 + 4 + 2 + name.size + 1 + pin.size + 1 + 4)
            .put("SBM1".toByteArray(Charsets.US_ASCII))
            // Protocol version: 2 = frame acks, 3 = pairing + input, 4 = flags, 5 = tap audio,
            // 6 = audio channel, 7 = extended display + screen size
            .put(7)
            .put(caps.codecMask.toByte())
            .putInt(caps.maxWidth)
            .putInt(caps.maxHeight)
            .putShort(name.size.toShort())
            .put(name)
            .put(pin.size.toByte())
            .put(pin)
            .put(((if (noVideo) 1 else 0) or (if (wantsAudio) 2 else 0) or (if (soundOnly) 4 else 0) or
                (if (extendDisplay) 8 else 0)).toByte())
            .putShort(screenSize.first.coerceAtMost(65535).toShort())
            .putShort(screenSize.second.coerceAtMost(65535).toShort())
            .array()
        send(MSG_HELLO, payload)
    }

    // MARK: Remote input (safe to call from any thread)

    fun mouseMove(dx: Int, dy: Int) {
        if (dx == 0 && dy == 0) return
        send(MSG_MOUSE_MOVE, ByteBuffer.allocate(4).putShort(dx.clampShort()).putShort(dy.clampShort()).array())
    }

    /** x, y in 0..1 across the Mac's screen. */
    fun mouseMoveAbsolute(x: Float, y: Float) = send(
        MSG_MOUSE_ABS,
        ByteBuffer.allocate(4)
            .putShort((x.coerceIn(0f, 1f) * 65535).toInt().toShort())
            .putShort((y.coerceIn(0f, 1f) * 65535).toInt().toShort()).array(),
    )

    fun mouseButton(button: Int, down: Boolean) =
        send(MSG_MOUSE_BUTTON, byteArrayOf(button.toByte(), if (down) 1 else 0))

    fun scroll(dx: Int, dy: Int) {
        if (dx == 0 && dy == 0) return
        send(MSG_SCROLL, ByteBuffer.allocate(4).putShort(dx.clampShort()).putShort(dy.clampShort()).array())
    }

    fun key(macKeyCode: Int, down: Boolean) =
        send(MSG_KEY, ByteBuffer.allocate(3).putShort(macKeyCode.toShort()).put(if (down) 1 else 0).array())

    fun text(text: String) {
        if (text.isNotEmpty()) send(MSG_TEXT, text.toByteArray(Charsets.UTF_8))
    }

    private fun Int.clampShort(): Short = coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()

    private fun sendKeyframeRequest() = send(MSG_KEYFRAME_REQUEST, ByteArray(0))

    private fun sendAck(ptsUs: Long) = send(MSG_ACK, ByteBuffer.allocate(8).putLong(ptsUs).array())

    private fun send(type: Int, payload: ByteArray) {
        outbox.offer(ByteBuffer.allocate(5 + payload.size).put(type.toByte()).putInt(payload.size).put(payload).array())
    }

    private class Config(val mime: String, val width: Int, val height: Int, val paramSets: List<ByteArray>)

    private fun parseConfig(buf: ByteArray, length: Int): Config {
        val bb = ByteBuffer.wrap(buf, 0, length)
        val codec = bb.get().toInt()
        val width = bb.int
        val height = bb.int
        val count = bb.get().toInt() and 0xff
        val sets = ArrayList<ByteArray>(count)
        repeat(count) {
            val len = bb.int
            val nal = ByteArray(len)
            bb.get(nal)
            sets += nal
        }
        val mime = if (codec == VideoDecoder.CODEC_HEVC) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        return Config(mime, width, height, sets)
    }

    private fun friendly(e: Exception): String = when (e) {
        is java.net.ConnectException -> "Mac not reachable. Is ScreenBeam running?"
        is java.net.SocketTimeoutException -> "Connection timed out"
        is java.net.NoRouteToHostException -> "No route to Mac. Are you on the same Wi-Fi?"
        is IllegalStateException -> e.message ?: "Decoder error"
        else -> "Connection lost"
    }

    private class ServerError(message: String) : Exception(message)

    companion object {
        private const val TAG = "ScreenBeam"
        private const val MAX_MESSAGE = 64 * 1024 * 1024

        const val DEFAULT_PORT = 7878
        private const val MSG_HELLO = 1
        private const val MSG_KEYFRAME_REQUEST = 2
        private const val MSG_PING = 3
        private const val MSG_ACK = 4
        private const val MSG_AUDIO_HELLO = 5
        private const val MSG_AUDIO_LATENCY = 6
        private const val MSG_MOUSE_MOVE = 20
        private const val MSG_MOUSE_ABS = 21
        private const val MSG_MOUSE_BUTTON = 22
        private const val MSG_SCROLL = 23
        private const val MSG_KEY = 24
        private const val MSG_TEXT = 25
        private const val MSG_CONFIG = 10
        private const val MSG_FRAME = 11
        private const val MSG_PONG = 12
        private const val MSG_ERROR = 13
        private const val MSG_STATS = 14
        private const val MSG_AUDIO = 15
        private const val MSG_READY = 16
        private const val MSG_AUDIO_LOW_LATENCY = 17
    }
}
