import AppKit
import CoreMedia
import ScreenCaptureKit

/// Captures the current macOS output mix and writes its PCM frames to a FIFO
/// consumed by the privileged A2DP worker. macOS asks for system-audio access.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let fifo: URL
    private let writerQueue = DispatchQueue(label: "local.rawbluetooth.audio-fifo")
    private let openQueue = DispatchQueue(label: "local.rawbluetooth.audio-fifo-open")
    private var outputFd: Int32 = -1
    private let stateLock = NSLock()
    private var stopped = false

    init(fifo: URL) {
        signal(SIGPIPE, SIG_IGN)
        self.fifo = fifo
    }

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
            guard fd >= 0 else { self.stop(); return }
            self.stateLock.lock()
            if self.stopped {
                self.stateLock.unlock()
                Darwin.close(fd)
                return
            }
            self.outputFd = fd
            self.stateLock.unlock()
        }
    }

    func stop() {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let fd = outputFd
        outputFd = -1
        stateLock.unlock()

        if fd >= 0 {
            Darwin.close(fd)
        }
        if let stream { Task { try? await stream.stopCapture() } }
        writerQueue.async {
            try? FileManager.default.removeItem(at: self.fifo)
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
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
        let frames = planar && list.count >= 2
            ? min(Int(list[0].mDataByteSize), Int(list[1].mDataByteSize)) / sampleBytes
            : (list.first.map { Int($0.mDataByteSize) / (sampleBytes * 2) } ?? 0)
        guard frames > 0 else { return }
        var input = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            for channel in 0..<2 {
                let buffer = list[planar ? channel : 0]
                guard let data = buffer.mData else { return }
                let index = planar ? frame : frame * 2 + channel
                let value: Float
                if isFloat && basic.mBitsPerChannel == 32 {
                    value = data.assumingMemoryBound(to: Float.self)[index]
                } else if basic.mBitsPerChannel == 16 {
                    value = Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                } else {
                    value = Float(Double(data.assumingMemoryBound(to: Int32.self)[index]) / 2147483648)
                }
                input[frame * 2 + channel] = value
            }
        }
        let outputFrames = max(1, Int(Double(frames) * 48000 / basic.mSampleRate))
        var pcm = [Float](repeating: 0, count: outputFrames * 2)
        for frame in 0..<outputFrames {
            let position = Double(frame) * basic.mSampleRate / 48000
            let low = min(Int(position), frames - 1)
            let high = min(low + 1, frames - 1)
            let fraction = Float(position - Double(low))
            for channel in 0..<2 {
                let a = input[low * 2 + channel]
                let b = input[high * 2 + channel]
                pcm[frame * 2 + channel] = a + (b - a) * fraction
            }
        }

        let written = pcm.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
        if written < 0 {
            let err = errno
            if err == EPIPE || err == EBADF {
                stop()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { stop() }
}
