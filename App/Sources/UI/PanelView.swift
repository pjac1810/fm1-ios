import SwiftUI
import UIKit
import FM1Engine

/// The FM-1's face, played with the fingers: the emulator's own drawing of the panel (keys,
/// buttons, knobs, LEDs), with the 240 x 240 screen on top of it in its own layer so the screen
/// can refresh at 60 Hz without redrawing the whole panel.
struct PanelView: UIViewRepresentable {
    var haptics: Bool

    func makeUIView(context: Context) -> PanelUIView {
        let v = PanelUIView()
        v.haptics = haptics
        return v
    }

    func updateUIView(_ v: PanelUIView, context: Context) {
        v.haptics = haptics
    }

    static func dismantleUIView(_ v: PanelUIView, coordinator: ()) {
        v.stop()
    }
}

final class PanelUIView: UIView {
    var haptics = true

    // the panel's geometry (fm1-live's panel.rs): 1280 x 820, the screen drawn at 2x from (370, 42)
    private let pw = CGFloat(fm1ios_panel_width())
    private let ph = CGFloat(fm1ios_panel_height())
    private let lcdOrigin = CGPoint(x: 370, y: 42)
    private let lcdSide: CGFloat = 480

    private let panelLayer = CALayer()
    private let lcdLayer = CALayer()
    private var link: CADisplayLink?
    private var fit = CGRect.zero
    private var scale: CGFloat = 1

    private var lcd = [UInt16](repeating: 0, count: 240 * 240)
    private var lcdRGBA = [UInt32](repeating: 0xff00_0000, count: 240 * 240)
    private var lcdRevision: UInt32 = .max
    private var leds = [Float](repeating: 0, count: 41)
    private var shownLeds = [UInt8](repeating: 255, count: 41)
    private var dirty = true
    private var lastDraw: CFTimeInterval = 0

    private enum Track {
        case key(Int32)
        case encoder(Int, CGFloat, CGPoint)  // panel index, accumulated travel, last point
        case pot(CGPoint)
    }
    private var tracks: [ObjectIdentifier: Track] = [:]
    private var held = Set<Int32>()
    private var encClicks = [Int32](repeating: 0, count: 8)
    private var glow = [Int32](repeating: 0, count: 9)
    private var pot = Settings.shared.pot
    private let tap = UIImpactFeedbackGenerator(style: .light)

    private static let rgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(red: 0x18 / 255, green: 0x19 / 255, blue: 0x1b / 255, alpha: 1)
        panelLayer.contentsGravity = .resize
        lcdLayer.contentsGravity = .resize
        lcdLayer.magnificationFilter = .linear
        layer.addSublayer(panelLayer)
        layer.addSublayer(lcdLayer)
        fm1ios_panel_set(2, 0, Int32(pot))
        tap.prepare()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
            becomeFirstResponder()
        } else if window == nil {
            stop()
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        scale = min(b.width / pw, b.height / ph)
        let size = CGSize(width: pw * scale, height: ph * scale)
        fit = CGRect(x: (b.width - size.width) / 2, y: (b.height - size.height) / 2, width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panelLayer.frame = fit
        lcdLayer.frame = CGRect(x: fit.minX + lcdOrigin.x * scale, y: fit.minY + lcdOrigin.y * scale,
                                width: lcdSide * scale, height: lcdSide * scale)
        CATransaction.commit()
    }

    // MARK: drawing

    @objc private func tick() {
        for i in 0..<glow.count where glow[i] > 0 {
            glow[i] -= 1
            fm1ios_panel_set(3, UInt32(i), glow[i])
            dirty = true
        }
        let rev = fm1ios_lcd_revision()
        if rev != lcdRevision {
            lcdRevision = fm1ios_lcd(&lcd)
            showLCD()
        }
        fm1ios_leds(&leds)
        for i in 0..<leds.count {
            let q = UInt8(max(0, min(1, leds[i])) * 4)
            if q != shownLeds[i] {
                shownLeds[i] = q
                dirty = true
            }
        }
        // the whole panel is 1280 x 820: redrawn at most 30 times a second
        let now = CACurrentMediaTime()
        if dirty, now - lastDraw >= 1.0 / 30 {
            dirty = false
            lastDraw = now
            drawPanel()
        }
    }

    private func showLCD() {
        for i in 0..<lcd.count {
            let p = UInt32(lcd[i])
            let r = (p >> 11) & 31, g = (p >> 5) & 63, b = p & 31
            lcdRGBA[i] = ((r << 3) | (r >> 2)) | (((g << 2) | (g >> 4)) << 8) | (((b << 3) | (b >> 2)) << 16) | 0xff00_0000
        }
        let data = lcdRGBA.withUnsafeBytes { Data($0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lcdLayer.contents = Self.image(data, width: 240, height: 240)
        CATransaction.commit()
    }

    private func drawPanel() {
        guard let p = fm1ios_panel_draw(lcd, leds) else { return }
        let w = Int(pw), h = Int(ph)
        let data = Data(bytes: p, count: w * h * 4)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panelLayer.contents = Self.image(data, width: w, height: h)
        CATransaction.commit()
    }

    /// RGBA bytes (alpha unused) as an image.
    private static func image(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: rgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: touch

    private func panelPoint(_ t: UITouch) -> CGPoint {
        let p = t.location(in: self)
        return CGPoint(x: (p.x - fit.minX) / scale, y: (p.y - fit.minY) / scale)
    }

    private func hit(_ p: CGPoint) -> Int32 {
        fm1ios_panel_hit(Float(p.x), Float(p.y))
    }

    private func press(_ id: Int32) {
        guard !held.contains(id) else { return }
        held.insert(id)
        fm1ios_key(UInt32(id), 1)
        fm1ios_panel_set(0, UInt32(id), 1)
        dirty = true
        if haptics { tap.impactOccurred(intensity: id < 14 ? 0.8 : 0.5) }
    }

    private func release(_ id: Int32) {
        guard held.contains(id) else { return }
        held.remove(id)
        fm1ios_key(UInt32(id), 0)
        fm1ios_panel_set(0, UInt32(id), 0)
        dirty = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = panelPoint(t)
            let h = hit(p)
            switch h {
            case 100...:
                let id = h - 100
                press(id)
                tracks[ObjectIdentifier(t)] = .key(id)
            case 0...6:
                tracks[ObjectIdentifier(t)] = .encoder(Int(h), 0, p)
                glow[Int(h)] = 12
                fm1ios_panel_set(3, UInt32(h), 12)
                dirty = true
            case 7:
                tracks[ObjectIdentifier(t)] = .pot(p)
                glow[7] = 12
                fm1ios_panel_set(3, 7, 12)
                dirty = true
            default:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let key = ObjectIdentifier(t)
            guard let track = tracks[key] else { continue }
            let p = panelPoint(t)
            switch track {
            case .key(let id):
                // a finger sliding along the keyboard plays the next note (not across buttons)
                guard id >= 14 else { break }
                let h = hit(p)
                if h >= 114, h - 100 != id, !held.contains(h - 100) {
                    release(id)
                    press(h - 100)
                    tracks[key] = .key(h - 100)
                }
            case .encoder(let i, var travel, let last):
                // right or up turns clockwise; one click per 14 panel pixels
                travel += (p.x - last.x) - (p.y - last.y)
                let step: CGFloat = 14
                let clicks = Int32((travel / step).rounded(.towardZero))
                if clicks != 0 {
                    travel -= CGFloat(clicks) * step
                    fm1ios_enc(fm1ios_panel_enc_id(UInt32(i)), clicks)
                    encClicks[i] &+= clicks
                    fm1ios_panel_set(1, UInt32(i), encClicks[i])
                    glow[i] = 12
                    fm1ios_panel_set(3, UInt32(i), 12)
                    dirty = true
                    if haptics { tap.impactOccurred(intensity: 0.3) }
                }
                tracks[key] = .encoder(i, travel, p)
            case .pot(let last):
                let v = max(0, min(1023, pot + Int(((last.y - p.y) + (p.x - last.x)) * 3)))
                if v != pot {
                    pot = v
                    Settings.shared.pot = v
                    fm1ios_pot(UInt32(v))
                    fm1ios_panel_set(2, 0, Int32(v))
                    glow[7] = 12
                    fm1ios_panel_set(3, 7, 12)
                    dirty = true
                }
                tracks[key] = .pot(p)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches {
            if case .key(let id) = tracks[ObjectIdentifier(t)] { release(id) }
            tracks[ObjectIdentifier(t)] = nil
        }
    }

    // MARK: a hardware keyboard (iPad, Bluetooth): the computer-keyboard piano of the emulator

    override var canBecomeFirstResponder: Bool { true }

    /// a s d f g h j k l ; ' as white keys from F, w e t y u o p as the black keys
    private static let keyMap: [String: Int32] = {
        let whites: [(String, Int32)] = [("a", 0), ("s", 2), ("d", 4), ("f", 6), ("g", 7), ("h", 9), ("j", 11),
                                         ("k", 12), ("l", 14), (";", 16), ("'", 18)]
        let blacks: [(String, Int32)] = [("w", 1), ("e", 3), ("r", 5), ("y", 8), ("u", 10), ("o", 13), ("p", 15)]
        var m: [String: Int32] = [:]
        for (k, n) in whites + blacks { m[k] = 14 + n }
        return m
    }()

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let k = p.key?.charactersIgnoringModifiers.lowercased(), let id = Self.keyMap[k] {
                press(id)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let k = p.key?.charactersIgnoringModifiers.lowercased(), let id = Self.keyMap[k] {
                release(id)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}
