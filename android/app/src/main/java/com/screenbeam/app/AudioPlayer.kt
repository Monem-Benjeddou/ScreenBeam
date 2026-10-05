package com.screenbeam.app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Process
import android.os.SystemClock
import android.util.Log
import kotlin.math.ceil
import kotlin.math.floor

/**
 * Plays the Mac's audio (PCM s16le stereo) without dropouts or clicks.
 *
 * - **Jitter-sized buffer:** the target fill is the worst packet delay seen in the last 10 s plus a
 *   margin (the USB tunnel stalls ~45 ms every few seconds; a smaller buffer would run dry each time).
 * - **No hard cuts:** the fill level is steered by playing up to ±2.5 % faster or slower (linear
 *   resampling), which is inaudible, instead of skipping or inserting audio.
 * - **Soft edges:** if it does run dry, it fades out and back in rather than clicking.
 */
class AudioPlayer {
    @Volatile var muted = false
        set(value) {
            field = value
            if (value) release()
        }

    private val lock = Object()
    private var ring = ShortArray(0) // interleaved stereo samples
    private var readPos = 0          // in samples
    private var levelFrames = 0
    private var sampleRate = 0
    private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var currentTrack: AudioTrack? = null
    @Volatile private var framesWritten = 0L

    /**
     * Delay from a packet arriving to it leaving the speaker: what's queued in the jitter buffer plus
     * what's inside the AudioTrack/HAL (from the hardware's presentation timestamp). The Mac delays its
     * own speakers by this much so both play in sync.
     */
    fun playoutLatencyMs(): Int? {
        val t = currentTrack ?: return null
        val rate = sampleRate.takeIf { it > 0 } ?: return null
        val levelMs = synchronized(lock) { levelFrames * 1000.0 / rate }
        val ts = AudioTimestamp()
        val trackMs = try {
            if (t.getTimestamp(ts)) {
                val presented = ts.framePosition + (System.nanoTime() - ts.nanoTime) * rate / 1e9
                ((framesWritten - presented) * 1000.0 / rate).coerceIn(0.0, 300.0)
            } else {
                30.0 // no timestamp yet: typical fast-path output delay
            }
        } catch (_: IllegalStateException) {
            return null
        }
        return (levelMs + trackMs).toInt()
    }

    // Jitter tracking (arrival gaps over the last 10 s), drives the target fill.
    private val gapTimes = ArrayDeque<Long>()
    private val gapValues = ArrayDeque<Long>()
    private var lastArrival = 0L
    @Volatile private var targetMs = 30

    /** Current jitter-buffer target; high values mean the link is jittery. */
    val currentTargetMs get() = targetMs
    private var lastTargetDecay = 0L

    // Diagnostics, logged every 5 s.
    private var statMaxGapMs = 0L
    private var statStarves = 0
    private var statLevelSumMs = 0L
    private var statPackets = 0
    private var statSince = SystemClock.elapsedRealtime()

    fun write(rate: Int, buf: ByteArray, offset: Int, length: Int) {
        if (muted || rate <= 0) return
        val frames = (length - length % 4) / 4
        if (frames <= 0) return
        synchronized(lock) {
            if (rate != sampleRate || thread == null) start(rate)
            trackJitter()

            // Way behind (long stall then a burst): drop the oldest audio, but only far past target;
            // normal drift is absorbed by the resampler.
            val maxFrames = (targetMs + 150) * sampleRate / 1000
            if (levelFrames + frames > maxFrames) {
                val drop = levelFrames + frames - targetMs * sampleRate / 1000
                val d = minOf(drop, levelFrames)
                readPos = (readPos + d * 2) % ring.size
                levelFrames -= d
            }
            var w = (readPos + levelFrames * 2) % ring.size
            var i = offset
            repeat(frames * 2) {
                ring[w] = ((buf[i].toInt() and 0xff) or (buf[i + 1].toInt() shl 8)).toShort()
                w = if (w + 1 == ring.size) 0 else w + 1
                i += 2
            }
            levelFrames += frames
            lock.notifyAll()
        }
    }

    fun release() {
        val t: Thread?
        synchronized(lock) {
            running = false
            t = thread
            thread = null
            levelFrames = 0
            lock.notifyAll()
        }
        t?.interrupt()
    }

    private fun trackJitter() {
        val now = SystemClock.elapsedRealtime()
        val gap = if (lastArrival == 0L) 0L else now - lastArrival
        lastArrival = now
        // Gaps over 300 ms are the Mac being silent (nothing playing), not network jitter.
        if (gap in 1..300) {
            gapTimes.addLast(now); gapValues.addLast(gap)
            statMaxGapMs = maxOf(statMaxGapMs, gap)
        }
        while (gapTimes.isNotEmpty() && now - gapTimes.first() > 10_000) {
            gapTimes.removeFirst(); gapValues.removeFirst()
        }
        // Size for the recurring worst case, not a single one-off spike (e.g. a reconnect):
        // use the 3rd-largest gap of the last 10 s.
        val jitter = gapValues.sortedDescending().getOrElse(2) { gapValues.maxOrNull() ?: 0L }
        val desired = (jitter + 8).toInt().coerceIn(20, 80)
        if (desired > targetMs) {
            targetMs = desired // grow immediately
        } else if (now - lastTargetDecay > 500 && targetMs > desired) {
            targetMs = maxOf(desired, targetMs - 5) // shrink quickly once things calm down
            lastTargetDecay = now
        }

        statPackets++
        statLevelSumMs += levelFrames * 1000L / sampleRate
        if (now - statSince > 5000) {
            Log.i("ScreenBeam", "audio stats: packets=$statPackets maxGap=${statMaxGapMs}ms starves=$statStarves " +
                "target=${targetMs}ms avgBuffered=${statLevelSumMs / maxOf(statPackets, 1)}ms")
            statMaxGapMs = 0; statStarves = 0; statLevelSumMs = 0; statPackets = 0; statSince = now
        }
    }

    private fun start(rate: Int) {
        // Fresh session: forget the previous connection's jitter history.
        gapTimes.clear(); gapValues.clear(); lastArrival = 0L; targetMs = 30
        running = false
        thread?.interrupt()
        sampleRate = rate
        ring = ShortArray(rate * 2) // 1 s
        readPos = 0
        levelFrames = 0
        running = true
        thread = Thread({ playLoop(rate) }, "ScreenBeam-audio").apply { start() }
    }

    private fun sample(frame: Int, channel: Int): Float = ring[(readPos + frame * 2 + channel) % ring.size].toFloat()

    private fun playLoop(rate: Int) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val track = createTrack(rate)
        framesWritten = 0
        currentTrack = track
        val outFrames = rate / 200 // 5 ms per write
        val out = ShortArray(outFrames * 2)
        var pos = 0.0               // fractional read position within the ring, in frames
        var buffering = true
        var fadeIn = false
        try {
            track.play()
            while (running) {
                var count: Int
                synchronized(lock) {
                    if (buffering) {
                        while (running && levelFrames < targetMs * rate / 1000) lock.wait(20)
                        if (!running) return
                        buffering = false
                        fadeIn = true
                        pos = 0.0
                    }
                    // Steer the fill level toward the target by playing slightly faster/slower.
                    val levelMs = levelFrames * 1000.0 / rate
                    val ratio = 1.0 + ((levelMs - targetMs) / targetMs * 0.03).coerceIn(-0.02, 0.025)
                    val needed = ceil(pos + outFrames * ratio).toInt() + 1
                    if (levelFrames < needed) {
                        // Ran dry: play what's left fading out, then rebuffer (no click).
                        val n = maxOf(0, levelFrames - 1)
                        for (i in 0 until n) {
                            val g = 1f - i.toFloat() / maxOf(n, 1)
                            out[i * 2] = (sample(i, 0) * g).toInt().toShort()
                            out[i * 2 + 1] = (sample(i, 1) * g).toInt().toShort()
                        }
                        readPos = (readPos + n * 2) % ring.size
                        levelFrames -= n
                        count = n * 2
                        buffering = true
                        if (SystemClock.elapsedRealtime() - lastArrival < 30) statStarves++
                    } else {
                        for (i in 0 until outFrames) {
                            val p = pos + i * ratio
                            val i0 = floor(p).toInt()
                            val f = (p - i0).toFloat()
                            val g = if (fadeIn) i.toFloat() / outFrames else 1f
                            for (c in 0..1) {
                                val s = sample(i0, c) * (1 - f) + sample(i0 + 1, c) * f
                                out[i * 2 + c] = (s * g).toInt().coerceIn(-32768, 32767).toShort()
                            }
                        }
                        fadeIn = false
                        val advance = pos + outFrames * ratio
                        val consumed = floor(advance).toInt()
                        pos = advance - consumed
                        readPos = (readPos + consumed * 2) % ring.size
                        levelFrames -= consumed
                        count = outFrames * 2
                    }
                }
                if (count > 0) {
                    track.write(out, 0, count) // blocking: paced by the hardware
                    framesWritten += count / 2
                }
            }
        } catch (_: InterruptedException) {
        } catch (e: IllegalStateException) {
            Log.w("ScreenBeam", "audio track failed", e)
        } finally {
            currentTrack = null
            try { track.pause(); track.flush(); track.release() } catch (_: IllegalStateException) {}
        }
    }

    private fun createTrack(rate: Int): AudioTrack {
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_GAME)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
            )
            .setBufferSizeInBytes(rate * 4 / 10) // 100 ms capacity...
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        // ...but only ~10 ms of it used, so the device side adds little delay; the jitter buffer does the rest.
        t.bufferSizeInFrames = maxOf(rate * 10 / 1000, 1)
        Log.i("ScreenBeam", "audio track: capacity ${t.bufferCapacityInFrames} frames, using ${t.bufferSizeInFrames}")
        return t
    }
}
