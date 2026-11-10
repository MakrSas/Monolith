import SwiftUI

/// A HomePod guest's top surface. It has no screen: its 19 LEDs (and the lit + and − marks) come from the
/// guest agent's `homepod.display.state`, which vphone's SoundBoard hook fills, and are drawn here as glows.
struct HomePodCap: View {
    @State private var leds: [Float] = [] // x, y (down), r, g, b per LED, for vphone's cap shader
    @State private var image: CGImage?
    @State private var plus = 0.0
    @State private var minus = 0.0
    @State private var waiting = true
    @State private var lastLogged = ""

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let _ = updateSide(side)
            Image(decorative: image ?? CapRenderer.render(leds: [], plus: 0, minus: 0), scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in touch(at: v.startLocation, in: v, began: true) }
            .onEnded { v in touch(at: v.startLocation, in: v, began: false) })
        .task { await poll() }
    }

    private func updateSide(_ s: CGFloat) -> Bool {
        if side != s { DispatchQueue.main.async { side = s } }
        return true
    }

    private func poll() async {
        GuestAgent.connect()
        while !Task.isCancelled {
            if let s = await GuestAgent.rpc("homepod.display.state", timeout: 2) {
                apply(s)
                note("state \(s["state"] as? String ?? "?"), frames \(s["frames_received"] as? Int ?? -1)")
            } else {
                note("no answer from the guest agent")
            }
            try? await Task.sleep(nanoseconds: waiting ? 1_000_000_000 : 50_000_000)
        }
    }

    // The top surface takes SoundBoard's own button events, as vphone sends them: 1 −, 2 +, 3 the centre;
    // actions 1 touch might have begun, 2 tap, 3 hold began, 4 hold ended.
    @State private var touchStart: Date?
    @State private var touchButton = 3
    @State private var holding = false
    @State private var pressed: Int?
    @State private var side: CGFloat = 1

    private func touch(at p: CGPoint, in v: DragGesture.Value, began: Bool) {
        if began, touchStart == nil {
            touchStart = Date()
            let x = p.x / max(side, 1)
            touchButton = x < 0.33 ? 1 : x > 0.67 ? 2 : 3
            pressed = touchButton
            send(1, touchButton, coalesced: false)
            let started = touchStart
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if touchStart == started, started != nil { holding = true; send(3, touchButton, coalesced: false) }
            }
        } else if !began {
            if holding { send(4, touchButton, coalesced: false) } else { send(2, touchButton, coalesced: true) }
            touchStart = nil
            holding = false
            pressed = nil
        }
    }

    private func send(_ action: Int, _ button: Int, coalesced: Bool) {
        let event: [String: Any] = ["action": action, "button": button, "coalesced": coalesced, "deviceSideways": false,
                                    "numberOfTaps": 1, "startMachTime": 0]
        Task {
            let r = await GuestAgent.rpc("homepod.debug.call", ["operation": "sendButtonCommand:", "arguments": ["event": event]], timeout: 8)
            HengeLog.log("homepod", "button \(button) action \(action): \(r.map { "\($0)" } ?? "no answer")")
        }
    }

    /// The log gets each change of what the agent says (not every poll).
    private func note(_ line: String) {
        let key = line.replacingOccurrences(of: #"frames \d+"#, with: "frames", options: .regularExpression)
        guard key != lastLogged else { return }
        lastLogged = key
        HengeLog.log("homepod", line)
    }

    private func apply(_ s: [String: Any]) {
        waiting = (s["state"] as? String) == "waiting_for_guest"
        // vphoned hands the colours over already as 0...1 (bit_depth is the hardware's, not the JSON's).
        let scale = 1.0
        guard let geo = s["geometry"] as? [String: Any], let xs = geo["x"] as? [Double], let ys = geo["y"] as? [Double],
              let rings = geo["rings"] as? [Int], var pixels = s["pixels"] as? [[Double]] else { return }
        // SoundBoard drives two layers over the same 19 LEDs (Siri, and the always-on one that carries setup's
        // white pulse and the idle glow); the top surface shows both, added.
        if let displays = s["displays"] as? [[String: Any]] {
            for d in displays.dropFirst() {
                guard let px = d["pixels"] as? [[Double]] else { continue }
                for i in 0..<min(px.count, pixels.count) where px[i].count >= 3 && pixels[i].count >= 3 {
                    for c in 0..<3 { pixels[i][c] = min(1, pixels[i][c] + px[i][c]) }
                }
            }
        }
        var out: [Float] = []
        for i in 0..<min(xs.count, ys.count, rings.count, pixels.count) where pixels[i].count >= 3 {
            let p = pixels[i]
            out += [Float(xs[i]), Float(1 - ys[i]), Float(p[0] / scale), Float(p[1] / scale), Float(p[2] / scale)]
        }
        leds = out
        image = CapRenderer.render(leds: out, plus: Float(min(1, ((s["plus"] as? Double) ?? 0) / scale)),
                                   minus: Float(min(1, ((s["minus"] as? Double) ?? 0) / scale)))
        plus = min(1, ((s["plus"] as? Double) ?? 0) / scale)
        minus = min(1, ((s["minus"] as? Double) ?? 0) / scale)
    }
}

/// vphone's HomePod top cap shader (VPhoneHomePodShader's capFragment), run on the CPU into a small image:
/// one optical model for all LEDs under the glass, etched − and + lit by their own channel, a faint rim.
enum CapRenderer {
    static let size = 192

    private static func stroke(_ px: Float, _ py: Float, _ cx: Float, _ cy: Float, plus: Bool, _ aa: Float) -> Float {
        let qx = abs(px - cx), qy = abs(py - cy)
        let horizontal = max(qx - 0.052, qy - 0.0026)
        let vertical = max(qx - 0.0026, qy - 0.052)
        return 1 - smoothstep(-aa, aa, plus ? min(horizontal, vertical) : horizontal)
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func encode(_ c: Float) -> UInt8 {
        let v = min(max(c, 0), 1)
        let e = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, e * 255 + 0.5)))
    }

    static func render(leds: [Float], plus plusLight: Float, minus minusLight: Float) -> CGImage {
        let n = size
        let radius = Float(n) / 2
        let aa = 0.65 / radius
        let count = leds.count / 5
        var out = [UInt8](repeating: 0, count: n * n * 4)
        let bg = encode(0.0044)
        for y in 0..<n {
            for x in 0..<n {
                let px = (Float(x) + 0.5) / Float(n), py = (Float(y) + 0.5) / Float(n)
                let dx0 = px - 0.5, dy0 = py - 0.5
                let r = (dx0 * dx0 + dy0 * dy0).squareRoot() * 2
                let o = (y * n + x) * 4
                out[o + 3] = 255
                if r > 1 + aa * 2 { out[o] = bg; out[o + 1] = bg; out[o + 2] = bg; continue }
                var lr: Float = 0, lg: Float = 0, lb: Float = 0, wsum: Float = 0
                for i in 0..<count {
                    let dx = px - leds[i * 5], dy = py - leds[i * 5 + 1]
                    let d2 = dx * dx + dy * dy
                    let w = 0.86 * exp(-d2 / (2 * 0.155 * 0.155)) + 0.14 * exp(-d2 / (2 * 0.29 * 0.29))
                    lr += leds[i * 5 + 2] * w; lg += leds[i * 5 + 3] * w; lb += leds[i * 5 + 4] * w
                    wsum += w
                }
                let norm = 1 / max(wsum, 0.001)
                let edge = (1 - smoothstep(0.70, 0.985, r)) * 1.55
                var c = [lr * norm * edge, lg * norm * edge, lb * norm * edge].map { $0 / (1 + 0.45 * $0) }
                let glass = 0.0014 + 0.0015 * pow(max(0, 1 - r * r), 3)
                let rx = px - 0.38, ry = py - 0.24
                let reflection = 0.0022 * exp(-(rx * rx + ry * ry) / 0.12)
                let minus = stroke(px, py, 0.20, 0.5, plus: false, aa * 0.5)
                let plus = stroke(px, py, 0.80, 0.5, plus: true, aa * 0.5)
                let mark = max(minus, plus)
                let rim = exp(-pow((r - 0.992) / max(aa * 1.7, 0.002), 2)) * 0.012
                let cover = 1 - smoothstep(1 - aa, 1 + aa, r)
                for k in 0..<3 {
                    var v = c[k] + glass + reflection
                    v = v + (0.006 + v * 0.12 - v) * mark
                    v += (minus * minusLight + plus * plusLight) * 0.9 + rim
                    c[k] = 0.0044 + (v - 0.0044) * cover
                    out[o + k] = encode(c[k])
                }
            }
        }
        let provider = CGDataProvider(data: Data(out) as CFData)!
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}
