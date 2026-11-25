import AppKit
import CoreMedia
import ScreenCaptureKit

/// Captures the current macOS output mix and writes its PCM frames to a FIFO
/// consumed by the privileged A2DP worker. macOS asks for system-audio access.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onStopped: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var stream: SCStream?
    private let fifo: URL
    private let writerQueue = DispatchQueue(label: "local.rawbluetooth.audio-fifo")
    private let openQueue = DispatchQueue(label: "local.rawbluetooth.audio-fifo-open")
    private var outputFd: Int32 = -1
    private var keepAliveTimer: DispatchSourceTimer?
    // A2DP sinks commonly suspend an otherwise valid stream after a few
    // seconds with no RTP packets. ScreenCaptureKit does not always emit
    // buffers while macOS is silent, so supply 20 ms of silent stereo PCM to
    // keep the SBC pipeline and sink alive between captured buffers.
    private let silenceFrame = [Float](repeating: 0, count: 960 * 2)
    private let pcmContext = rawbt_pcm_create()
    private var lastAudioWriteNs: UInt64 = 0
    private var loggedSilence = false
    private var loggedCaptureAudio = false
    private let stateLock = NSLock()
    private var stopped = false

    init(fifo: URL) {
        signal(SIGPIPE, SIG_IGN)
        self.fifo = fifo
    }

    deinit { rawbt_pcm_destroy(pcmContext) }

    func start() async throws {
        signal(SIGPIPE, SIG_IGN)
        guard #available(macOS 13.0, *) else {
            throw NSError(domain: "RawBluetoothAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "System audio capture requires macOS 13 or later."])
        }
        var info = stat()
        if lstat(fifo.path, &info) != 0 {
            guard mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "RawBluetoothAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display is available for system-audio capture."])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        stream = capture
        try await capture.startCapture()
        // Open the FIFO writer on a separate queue. The open(2) blocks until
        // the reader (ffmpeg in Python) opens its end; keeping this off the
        // writerQueue prevents audio-callback starvation and stop() deadlocks.
        openQueue.async {
            guard !self.isStopped else { return }
            let fd = Darwin.open(self.fifo.path, O_WRONLY)
            guard fd >= 0 else {
                let error = errno
                self.stop(reason: "FIFO writer open failed: \(String(cString: strerror(error)))")
                return
            }
            self.stateLock.lock()
            if self.stopped {
                self.stateLock.unlock()
                Darwin.close(fd)
                return
            }
            self.outputFd = fd
            self.stateLock.unlock()
            self.writerQueue.async {
                guard !self.isStopped else { return }
                self.lastAudioWriteNs = DispatchTime.now().uptimeNanoseconds
                self.startKeepAlive()
                self.diagnose("FIFO writer opened; silence keep-alive armed")
            }
        }
    }

    func stop(reason: String = "stopped by app") {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let fd = outputFd
        outputFd = -1
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        stateLock.unlock()

        if fd >= 0 {
            Darwin.close(fd)
        }
        if let stream { Task { try? await stream.stopCapture() } }
        writerQueue.async {
            try? FileManager.default.removeItem(at: self.fifo)
        }
        DispatchQueue.main.async { [weak self] in self?.onStopped?(reason) }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    // Called only from writerQueue, which also serializes real capture buffers
    // and the silence writes so their PCM bytes cannot interleave in the FIFO.
    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.writeSilenceIfNeeded() }
        keepAliveTimer = timer
        timer.resume()
    }

    private func diagnose(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onDiagnostic?(message) }
    }

    private func writeSilenceIfNeeded() {
        guard !isStopped else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastAudioWriteNs >= 40_000_000 else { return }
        stateLock.lock()
        let fd = outputFd
        stateLock.unlock()
        guard fd >= 0 else { return }
        let expected = silenceFrame.count * MemoryLayout<Float>.size
        let written = silenceFrame.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
        if written == expected {
            lastAudioWriteNs = now
            if !loggedSilence {
                loggedSilence = true
                diagnose("silence keep-alive is writing PCM")
            }
        } else if written < 0 {
            let error = errno
            if error == EPIPE || error == EBADF {
                stop(reason: "FIFO writer closed: \(String(cString: strerror(error)))")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !isStopped, CMSampleBufferIsValid(sampleBuffer) else { return }
        stateLock.lock()
        let fd = outputFd
        stateLock.unlock()
        guard fd >= 0 else { return }

        var needed = 0
        var retained: CMBlockBuffer?
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retained)
        guard needed > 0 else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              basic.mFormatID == kAudioFormatLinearPCM,
              basic.mChannelsPerFrame == 2,
              basic.mSampleRate >= 8000, basic.mSampleRate <= 96000,
              (basic.mBitsPerChannel == 16 || basic.mBitsPerChannel == 32) else { return }
        let isFloat = basic.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSigned = basic.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        guard isFloat || isSigned else { return }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { storage.deallocate() }
        let buffers = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: buffers,
            bufferListSize: needed, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retained) == noErr else { return }
        let list = UnsafeMutableAudioBufferListPointer(buffers)

        let sampleBytes = Int(basic.mBitsPerChannel / 8)
        let planar = basic.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard let first = list.first, let left = first.mData else { return }
        let right: UnsafeMutableRawPointer?
        let frames: Int
        if planar {
            guard list.count >= 2, let second = list[1].mData else { return }
            right = second
            frames = min(Int(first.mDataByteSize), Int(list[1].mDataByteSize)) / sampleBytes
        } else {
            right = nil
            frames = Int(first.mDataByteSize) / (sampleBytes * 2)
        }
        var samples = 0
        let converted = withExtendedLifetime(retained) {
            rawbt_pcm_convert(pcmContext, left, right, frames, Int32(basic.mBitsPerChannel),
                              isFloat ? 1 : 0, basic.mSampleRate, &samples)
        }
        guard let pcm = converted else { return }
        let expected = samples * MemoryLayout<Float>.size
        let written = Darwin.write(fd, pcm, expected)
        if written == expected {
            lastAudioWriteNs = DispatchTime.now().uptimeNanoseconds
            if !loggedCaptureAudio {
                loggedCaptureAudio = true
                diagnose("received system-audio PCM from ScreenCaptureKit")
            }
        } else if written < 0 {
            let err = errno
            if err == EPIPE || err == EBADF {
                stop(reason: "FIFO writer closed: \(String(cString: strerror(err)))")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stop(reason: "ScreenCaptureKit stopped: \(error.localizedDescription)")
    }
}
