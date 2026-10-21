import UIKit
import AVFoundation
import CoreMedia

/// Displays the H.264 stream with hardware decoding (AVSampleBufferDisplayLayer).
final class VideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private let lock = NSLock()

    /// Called when the decoder needs a fresh keyframe.
    var onNeedKeyframe: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resize
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Thread‑safe.
    func setFormat(sps: Data, pps: Data) {
        var desc: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                let pointers = [spsRaw.bindMemory(to: UInt8.self).baseAddress!, ppsRaw.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let desc else { return }
        lock.lock()
        if let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: desc) {
            lock.unlock()
            return
        }
        format = desc
        lock.unlock()
    }

    /// Thread‑safe. `avcc` holds length‑prefixed NAL units.
    func enqueue(avcc: Data, isKeyframe: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let format else { return }
        if waitingForKeyframe {
            guard isKeyframe else { return }
            waitingForKeyframe = false
        }
        if displayLayer.status == .failed {
            displayLayer.flush()
            waitingForKeyframe = true
            onNeedKeyframe?()
            return
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        avcc.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        displayLayer.enqueue(sample)
    }

    func reset() {
        lock.lock()
        displayLayer.flush()
        waitingForKeyframe = true
        lock.unlock()
    }
}
