import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "No display is available to capture." }
}

/// Wraps an SCStream that delivers NV12 frames (what the hardware encoder wants, so no conversion).
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue: DispatchQueue
    private var stream: SCStream?

    /// Called on `queue` for every new, complete frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Called on the audio queue with system audio (when started with audio).
    var onAudio: ((CMSampleBuffer) -> Void)?
    private let audioQueue = DispatchQueue(label: "screenbeam.audio", qos: .userInteractive)
    /// Called (on an arbitrary queue) if the system stops the stream.
    var onStop: ((Error) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// `waitForDisplay`: a display that was just created (the virtual one) takes a moment to show up.
    static func makeFilter(displayID: CGDirectDisplayID, waitForDisplay: Bool = false) async throws -> SCContentFilter {
        let wanted = displayID == 0 ? CGMainDisplayID() : displayID
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var tries = 0
        while waitForDisplay, tries < 30, !content.displays.contains(where: { $0.displayID == wanted }) {
            try await Task.sleep(nanoseconds: 100_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            tries += 1
        }
        guard let display = content.displays.first(where: { $0.displayID == wanted })
            ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        else { throw CaptureError.noDisplay }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    /// Native pixel size of the filter's content (points × backing scale).
    static func nativePixelSize(of filter: SCContentFilter) -> (width: Int, height: Int) {
        let scale = CGFloat(filter.pointPixelScale)
        return (Int(filter.contentRect.width * scale), Int(filter.contentRect.height * scale))
    }

    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, audio: Bool) async throws {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = true
        config.scalesToFit = true
        config.captureResolution = .best
        config.queueDepth = 6
        config.capturesAudio = audio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sampleBuffer.isValid { onAudio?(sampleBuffer) }
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ScreenBeam: capture stopped: \(error.localizedDescription)")
        onStop?(error)
    }
}
