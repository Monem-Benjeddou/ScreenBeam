package com.screenbeam.app

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Hardware decoder rendering straight to a Surface, configured for lowest latency.
 * [configure] and [decode] are called from the network thread; codec callbacks run on a private thread.
 */
class VideoDecoder(
    private val surface: Surface,
    private val requestKeyframe: () -> Unit,
    /** Called with the pts of every frame handed to the display (drives the Mac's flow control). */
    private val onRendered: (Long) -> Unit,
) {
    val framesRendered = AtomicInteger()
    /** Longest time the network thread waited for a decoder input buffer (diagnostics). */
    @Volatile var maxInputWaitMs = 0L

    private val callbackThread = HandlerThread("ScreenBeam-decoder").apply { start() }
    private val callbackHandler = Handler(callbackThread.looper)
    private val freeInputs = LinkedBlockingQueue<Int>()

    @Volatile private var codec: MediaCodec? = null
    @Volatile private var broken = false
    private var currentConfig: ByteArray? = null
    private var waitingForKeyframe = true

    /** Returns true if the decoder was (re)created, i.e. the video format changed. */
    fun configure(rawConfig: ByteArray, mime: String, width: Int, height: Int, paramSets: List<ByteArray>): Boolean {
        if (!broken && codec != null && currentConfig.contentEquals(rawConfig)) return false
        releaseCodec()

        // Safe mode (after repeated crashes) skips the vendor low-latency keys, the riskiest part.
        val format = buildFormat(mime, width, height, paramSets, lowLatencyExtras = !CrashGuard.safeMode)
        val created = createCodec(mime, format)
            ?: createCodec(mime, buildFormat(mime, width, height, paramSets, lowLatencyExtras = false))
            ?: throw IllegalStateException("This phone can't decode ${width}x$height video")
        codec = created
        broken = false
        currentConfig = rawConfig
        waitingForKeyframe = true
        return true
    }

    fun decode(data: ByteArray, offset: Int, length: Int, isKeyframe: Boolean, ptsUs: Long) {
        val c = codec ?: return
        if (broken) {
            // Decoder hit an error: drop everything until the next keyframe (which carries a config).
            currentConfig = null
            waitingForKeyframe = true
            return
        }
        if (waitingForKeyframe && !isKeyframe) return

        val waitStart = System.nanoTime()
        val index = freeInputs.poll(40, TimeUnit.MILLISECONDS)
        val waitedMs = (System.nanoTime() - waitStart) / 1_000_000
        if (waitedMs > maxInputWaitMs) maxInputWaitMs = waitedMs
        if (index == null) {
            // Decoder is backed up; skipping a frame would corrupt the picture, so resync on a keyframe.
            waitingForKeyframe = true
            requestKeyframe()
            return
        }
        try {
            val buffer = c.getInputBuffer(index) ?: return
            if (length > buffer.capacity()) {
                Log.w(TAG, "frame of $length bytes exceeds input buffer ${buffer.capacity()}")
                c.queueInputBuffer(index, 0, 0, ptsUs, 0)
                waitingForKeyframe = true
                requestKeyframe()
                return
            }
            buffer.clear()
            buffer.put(data, offset, length)
            c.queueInputBuffer(index, 0, length, ptsUs, if (isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            waitingForKeyframe = false
        } catch (e: IllegalStateException) {
            Log.w(TAG, "decode failed", e)
            broken = true
            requestKeyframe()
        }
    }

    fun release() {
        releaseCodec()
        callbackThread.quitSafely()
    }

    private fun releaseCodec() {
        val c = codec ?: return
        codec = null
        try { c.stop() } catch (_: Exception) {}
        try { c.release() } catch (_: Exception) {}
        freeInputs.clear()
        currentConfig = null
    }

    private fun createCodec(mime: String, format: MediaFormat): MediaCodec? {
        var c: MediaCodec? = null
        return try {
            c = MediaCodec.createDecoderByType(mime)
            freeInputs.clear()
            c.setCallback(Callback(c), callbackHandler)
            c.configure(format, surface, null, 0)
            c.start()
            Log.i(TAG, "decoder ${c.name} started: $format")
            c
        } catch (e: Exception) {
            Log.w(TAG, "decoder configure failed", e)
            try { c?.release() } catch (_: Exception) {}
            null
        }
    }

    private fun buildFormat(
        mime: String, width: Int, height: Int, paramSets: List<ByteArray>, lowLatencyExtras: Boolean,
    ): MediaFormat {
        val format = MediaFormat.createVideoFormat(mime, width, height)
        if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) {
            format.setByteBuffer("csd-0", annexB(paramSets))
        } else {
            // H.264 wants SPS in csd-0 and PPS in csd-1.
            format.setByteBuffer("csd-0", annexB(paramSets.filter { it.isNotEmpty() && (it[0].toInt() and 0x1f) == 7 }))
            format.setByteBuffer("csd-1", annexB(paramSets.filter { it.isNotEmpty() && (it[0].toInt() and 0x1f) == 8 }))
        }
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(width * height, 2 * 1024 * 1024))
        format.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
        format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
        format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        if (lowLatencyExtras) {
            format.setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            // Qualcomm (Snapdragon Galaxy devices): output frames without waiting for a reorder window.
            format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
        }
        return format
    }

    private fun annexB(nals: List<ByteArray>): ByteBuffer {
        val size = nals.sumOf { it.size + 4 }
        val buf = ByteBuffer.allocate(size)
        for (nal in nals) {
            buf.put(START_CODE)
            buf.put(nal)
        }
        buf.flip()
        return buf
    }

    private inner class Callback(private val owner: MediaCodec) : MediaCodec.Callback() {
        override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {
            if (owner === codec) freeInputs.offer(index)
        }

        override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (owner !== codec) return
            try {
                // Render now. Passing an explicit "now" timestamp matters: with render=true Android
                // would use the frame's pts (the Mac's clock) and might hold it back to "present on time".
                if (info.size > 0) {
                    mc.releaseOutputBuffer(index, System.nanoTime())
                    framesRendered.incrementAndGet()
                } else {
                    mc.releaseOutputBuffer(index, false)
                }
                onRendered(info.presentationTimeUs)
            } catch (e: IllegalStateException) {
                Log.w(TAG, "release output failed", e)
            }
        }

        override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
            if (owner !== codec) return
            Log.e(TAG, "decoder error (recoverable=${e.isRecoverable}, transient=${e.isTransient})", e)
            if (!e.isTransient) {
                broken = true
                requestKeyframe()
            }
        }

        override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
            Log.i(TAG, "output format: $format")
        }
    }

    companion object {
        private const val TAG = "ScreenBeam"
        private val START_CODE = byteArrayOf(0, 0, 0, 1)

        const val CODEC_H264 = 1
        const val CODEC_HEVC = 2

        data class Capabilities(val codecMask: Int, val maxWidth: Int, val maxHeight: Int)

        /** What this phone's hardware decoders can handle, sent to the Mac in the hello. */
        /** Scanning MediaCodecList is slow; the answer never changes while the app runs. */
        fun capabilities(): Capabilities = cachedCapabilities

        private val cachedCapabilities: Capabilities by lazy { scanCapabilities() }

        private fun scanCapabilities(): Capabilities {
            var mask = 0
            var maxW = 0
            var maxH = 0
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            for ((bit, mime) in listOf(CODEC_H264 to MediaFormat.MIMETYPE_VIDEO_AVC, CODEC_HEVC to MediaFormat.MIMETYPE_VIDEO_HEVC)) {
                val info = list.codecInfos.firstOrNull { info ->
                    !info.isEncoder &&
                        info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
                        (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || info.isHardwareAccelerated)
                } ?: continue
                mask = mask or bit
                val video = info.getCapabilitiesForType(mime).videoCapabilities ?: continue
                maxW = maxOf(maxW, video.supportedWidths.upper)
                maxH = maxOf(maxH, video.supportedHeights.upper)
            }
            if (mask == 0) mask = CODEC_H264 // software fallback still decodes H.264
            return Capabilities(mask, if (maxW > 0) maxW else 1920, if (maxH > 0) maxH else 1080)
        }
    }
}
