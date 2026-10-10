// MastiKhor — a transparent floating dancer that reacts to Apple Music.
// Shinchan dances (from shinchan.gif) whenever Apple Music is playing.
import AppKit
import QuartzCore
import AVFoundation


// MARK: - Apple Music watcher (event-driven, zero polling)

final class MusicWatcher {
    var onChange: ((_ playing: Bool, _ artist: String, _ title: String) -> Void)?

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfo(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
    }

    func stop() { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func playerInfo(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        let title = info["Name"] as? String ?? ""
        onChange?(state == "Playing", artist, title)
    }
}

// MARK: - Clips: decode, crop, and make the baked-in background transparent

struct Clip {
    let frames: [CGImage]
    let duration: Double   // seconds for one pass
}

enum Source {
    case gif(name: String, crop: CGRect)
    case video(name: String, crop: CGRect, scale: CGFloat, everyNth: Int)

    var name: String {
        switch self { case .gif(let n, _), .video(let n, _, _, _): return n }
    }
}

enum ClipLoader {
    static func load(_ source: Source) -> Clip {
        switch source {
        case .gif(let name, let crop): return loadGif(name, crop)
        case .video(let name, let crop, let scale, let nth): return loadVideo(name, crop, scale, nth)
        }
    }

    // GIF: dithered pale-colour checkerboard behind the dancer.
    private static func loadGif(_ name: String, _ crop: CGRect) -> Clip {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return Clip(frames: [], duration: 1) }
        var frames: [CGImage] = []
        var total = 0.0
        for i in 0..<CGImageSourceGetCount(src) {
            if let img = CGImageSourceCreateImageAtIndex(src, i, nil)?.cropping(to: crop),
               let keyed = removeBackground(img, isBackground: { r, g, b in r >= 0xd0 && g >= 0xd0 && b >= 0xa8 }) {
                frames.append(keyed)
            }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            total += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0.1
        }
        return Clip(frames: frames, duration: max(total, 0.1))
    }

    // MP4: white / light-grey checkerboard. Frames are downscaled to keep memory small.
    private static func loadVideo(_ name: String, _ crop: CGRect, _ scale: CGFloat, _ nth: Int) -> Clip {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else { return Clip(frames: [], duration: 1) }
        let asset = AVURLAsset(url: url)
        // Blocking is fine: this runs on a background queue (or once in --dump).
        var loaded: AVAssetTrack?
        let sem = DispatchSemaphore(value: 0)
        Task { loaded = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }
        sem.wait()
        guard let track = loaded, let reader = try? AVAssetReader(asset: asset) else { return Clip(frames: [], duration: 1) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        let w = Int(crop.width * scale), h = Int(crop.height * scale)
        var frames: [CGImage] = []
        var n = 0
        while let sample = out.copyNextSampleBuffer() {
            defer { n += 1 }
            guard n % nth == 0, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let full = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb),
                                       height: CVPixelBufferGetHeight(pb), bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage(),
                  let cropped = full.cropping(to: crop),
                  let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            small.interpolationQuality = .high
            small.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let img = small.makeImage(),
               let keyed = removeBackground(img, isBackground: { r, g, b in
                   min(r, g, b) > 196 && max(r, g, b) - min(r, g, b) < 16 }) { frames.append(keyed) }
        }
        let fps = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 24)
        return Clip(frames: frames, duration: Double(n) / fps)
    }

    /// Flood-fills background-like pixels from the border, so white eyes/socks/collars inside the outline survive.
    static func removeBackground(_ img: CGImage, isBackground: (Int, Int, Int) -> Bool) -> CGImage? {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let p = stack.popLast() {
            if seen[p] || !isBackground(Int(px[p * 4]), Int(px[p * 4 + 1]), Int(px[p * 4 + 2])) { continue }
            seen[p] = true
            px[p * 4] = 0; px[p * 4 + 1] = 0; px[p * 4 + 2] = 0; px[p * 4 + 3] = 0
            let x = p % w, y = p / w
            if x > 0 { stack.append(p - 1) }
            if x < w - 1 { stack.append(p + 1) }
            if y > 0 { stack.append(p - w) }
            if y < h - 1 { stack.append(p + w) }
        }
        return ctx.makeImage()
    }
}

// MARK: - Dancer view (GPU-driven frame animation, ~0% CPU)
// Plays the playlist in order, forever: Aman once, then Shinchan a few times, repeat.
// Only the current clip (plus the next one while it preloads) is kept in memory.

final class DancerView: NSView, CAAnimationDelegate {
    private struct Entry { let source: Source; let loops: Float }
    private let playlist: [Entry] = [
        Entry(source: .video(name: "aman", crop: CGRect(x: 380, y: 0, width: 520, height: 720), scale: 0.3, everyNth: 2), loops: 1),
        Entry(source: .gif(name: "shinchan", crop: CGRect(x: 190, y: 60, width: 260, height: 290)), loops: 3),
    ]
    private let figure = CALayer()
    private var index = 0
    private var current: Clip?
    private var next: Clip?
    private var playing = false
    private var generation = 0   // invalidates stale animation callbacks and preloads

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        figure.frame = bounds
        figure.contentsGravity = .resizeAspect
        layer?.addSublayer(figure)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func dance(_ on: Bool) {
        generation += 1
        figure.removeAllAnimations()
        playing = on
        isHidden = !on
        if on { playCurrent() } else { current = nil; next = nil }   // free the frames while paused
    }

    private func playCurrent() {
        let gen = generation
        let clip = current ?? ClipLoader.load(playlist[index].source)
        current = clip
        guard !clip.frames.isEmpty else { advance(); return }
        figure.contents = clip.frames.first
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = clip.frames
        a.calculationMode = .discrete
        a.duration = clip.duration
        a.repeatCount = playlist[index].loops
        a.delegate = self
        figure.add(a, forKey: "dance")
        // Preload the next clip off the main thread while this one plays.
        let nextIndex = (index + 1) % playlist.count
        let src = playlist[nextIndex].source
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = ClipLoader.load(src)
            DispatchQueue.main.async { if self?.generation == gen { self?.next = loaded } }
        }
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, playing else { return }
        advance()
    }

    private func advance() {
        index = (index + 1) % playlist.count
        current = next
        next = nil
        generation += 1
        playCurrent()
    }
}

// MARK: - Window + toggle button

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var dancer: DancerView!
    private var button: NSButton!
    private let watcher = MusicWatcher()
    private var enabled = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let size = NSSize(width: 260, height: 320)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel = NSPanel(contentRect: NSRect(x: screen.maxX - size.width - 20, y: screen.minY + 20,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        dancer = DancerView(frame: NSRect(x: 0, y: 28, width: size.width, height: size.height - 28))
        dancer.isHidden = true
        dancer.menu = makeMenu()
        root.addSubview(dancer)

        button = NSButton(frame: NSRect(x: size.width / 2 - 13, y: 0, width: 26, height: 26))
        button.bezelStyle = .circular
        button.isBordered = false
        button.target = self
        button.action = #selector(toggle)
        button.menu = makeMenu()
        root.addSubview(button)
        updateButton()

        panel.contentView = root
        panel.orderFrontRegardless()

        watcher.onChange = { [weak self] playing, artist, _ in self?.handle(playing: playing, artist: artist) }
    }

    @objc private func toggle() {
        enabled.toggle()
        updateButton()
        if enabled {
            watcher.start()
            // Pick up a song that's already playing when you switch on.
            askMusicForCurrentState()
        } else {
            watcher.stop()
            dancer.dance(false)
        }
    }

    private func updateButton() {
        let name = enabled ? "music.note" : "music.note"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Toggle dancer")?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = enabled ? .systemPink : .secondaryLabelColor
    }

    private func handle(playing: Bool, artist: String) {
        guard enabled else { return }
        dancer.dance(playing)
    }

    private func askMusicForCurrentState() {
        // Only query if Music is already running (don't launch it).
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil else { return }
        let src = """
        tell application "Music"
            if player state is playing then return "1|" & (artist of current track)
            return "0|"
        end tell
        """
        DispatchQueue.global().async {
            var err: NSDictionary?
            let out = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue ?? "0|"
            let parts = out.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            DispatchQueue.main.async {
                self.handle(playing: parts.first == "1", artist: parts.count > 1 ? String(parts[1]) : "")
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return m
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--dump" {   // debug: write keyed frames
    let rootDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    _ = rootDir
    let fr = ClipLoader.load(.video(name: "aman", crop: CGRect(x: 380, y: 0, width: 520, height: 720), scale: 0.3, everyNth: 2)).frames
    let w = fr.first!.width, h = fr.first!.height
    let ctx = CGContext(data: nil, width: w * 6, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w * 6, height: h))
    for k in 0..<6 { ctx.draw(fr[k * fr.count / 6], in: CGRect(x: k * w, y: 0, width: w, height: h)) }
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("frames", fr.count)
    exit(0)
}
app.run()
