import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import QuartzCore

/// Draws the player's video with frame blending, for speeds below 1×. Slowed down, a 30 fps
/// video only shows a new frame every few refreshes and visibly steps; here every display
/// refresh cross-fades between the two nearest frames by how far playback is between them.
/// Runs one frame behind, which a wallpaper never notices.
@MainActor
final class FrameBlendView: NSView {
    weak var player: AVPlayer?

    /// Starts and stops the display link and the per-item video outputs.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? activate() : deactivate()
        }
    }

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue = device?.makeCommandQueue()
    private lazy var context: CIContext? = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
    private let metalLayer = CAMetalLayer()
    private var displayLink: CADisplayLink?

    /// One output per item: AVPlayerLooper plays several copies of the item in turn.
    private let outputs = NSMapTable<AVPlayerItem, AVPlayerItemVideoOutput>.weakToStrongObjects()
    private weak var frameItem: AVPlayerItem?
    private var previous: (image: CIImage, time: Double)?
    private var current: (image: CIImage, time: Double)?
    private var lastDrawn: (time: Double, phase: Double)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.isOpaque = true
        layer = metalLayer
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        lastDrawn = nil
    }

    // MARK: - Activation

    private func activate() {
        guard device != nil, displayLink == nil else { return }
        // Tied to this view's screen, so it ticks at that display's refresh rate.
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func deactivate() {
        displayLink?.invalidate()
        displayLink = nil
        isHidden = true
        let items = outputs.keyEnumerator().allObjects.compactMap { $0 as? AVPlayerItem }
        for item in items {
            if let output = outputs.object(forKey: item) { item.remove(output) }
        }
        outputs.removeAllObjects()
        frameItem = nil
        previous = nil
        current = nil
        lastDrawn = nil
    }

    private func output(for item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let output = outputs.object(forKey: item) { return output }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        outputs.setObject(output, forKey: item)
        return output
    }

    // MARK: - Drawing

    @objc private func tick(_ link: CADisplayLink) {
        guard let item = player?.currentItem else { return }
        if item !== frameItem {
            // A new video or the next loop: don't blend across it.
            frameItem = item
            previous = nil
            current = nil
        }

        let output = output(for: item)
        let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            var displayTime = CMTime.zero
            if let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) {
                previous = current
                current = (CIImage(cvPixelBuffer: buffer), CMTimeGetSeconds(displayTime))
            }
        }
        guard let current else { return }

        // How far playback has moved from `current` towards the frame after it, using the
        // previous frame gap as the frame duration. Drawn one frame behind: previous → current.
        var phase = 1.0
        if let previous, current.time > previous.time {
            let now = CMTimeGetSeconds(itemTime)
            phase = min(max((now - current.time) / (current.time - previous.time), 0), 1)
        }
        // Paused or between refreshes with nothing new: leave the last drawable up.
        if let lastDrawn, lastDrawn.time == current.time, abs(lastDrawn.phase - phase) < 0.01 { return }

        var image = current.image
        if let previous, phase < 1 {
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = previous.image
            dissolve.targetImage = current.image
            dissolve.time = Float(phase)
            image = dissolve.outputImage ?? current.image
        }
        if draw(image) {
            lastDrawn = (current.time, phase)
            isHidden = false
        }
    }

    /// Aspect-fills `image` into the drawable, like the player layer's `.resizeAspectFill`.
    private func draw(_ image: CIImage) -> Bool {
        guard let context, let commandQueue, let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return false }

        let size = metalLayer.drawableSize
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, size.width > 0, size.height > 0 else { return false }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let fitted = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = (fitted.extent.width - size.width) / 2
        let offsetY = (fitted.extent.height - size.height) / 2
        let placed = fitted
            .transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
            .cropped(to: CGRect(origin: .zero, size: size))

        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commandBuffer)
        // Core Image's origin is bottom-left; the drawable's is top-left.
        destination.isFlipped = true
        guard (try? context.startTask(toRender: placed, to: destination)) != nil else { return false }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }
}
