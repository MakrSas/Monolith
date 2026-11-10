import SwiftUI

/// A HomePod guest's top surface. It has no screen: its 19 LEDs (and the lit + and − marks) come from the
/// guest agent's `homepod.display.state`, which vphone's SoundBoard hook fills, and are drawn here as glows.
struct HomePodCap: View {
    @State private var leds: [(x: CGFloat, y: CGFloat, ring: Int, color: Color)] = []
    @State private var plus = 0.0
    @State private var minus = 0.0
    @State private var waiting = true
    @State private var lastLogged = ""

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let _ = updateSide(side)
            ZStack {
                Circle().fill(Color(white: 0.06))
                ForEach(leds.indices, id: \.self) { i in
                    let led = leds[i]
                    Circle()
                        .fill(led.color)
                        .frame(width: side * (led.ring == 0 ? 0.42 : led.ring == 1 ? 0.32 : 0.26),
                               height: side * (led.ring == 0 ? 0.42 : led.ring == 1 ? 0.32 : 0.26))
                        .blur(radius: side * 0.06)
                        .position(x: led.x * side, y: (1 - led.y) * side)
                        .blendMode(.screen)
                }
                Image(systemName: "minus")
                    .font(.system(size: side * 0.12, weight: .light))
                    .foregroundStyle(.white.opacity(0.15 + 0.85 * minus))
                    .position(x: side * 0.22, y: side * 0.5)
                Image(systemName: "plus")
                    .font(.system(size: side * 0.12, weight: .light))
                    .foregroundStyle(.white.opacity(0.15 + 0.85 * plus))
                    .position(x: side * 0.78, y: side * 0.5)
            }
            .frame(width: side, height: side)
            .clipShape(Circle())
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
    @State private var side: CGFloat = 1

    private func touch(at p: CGPoint, in v: DragGesture.Value, began: Bool) {
        if began, touchStart == nil {
            touchStart = Date()
            let x = p.x / max(side, 1)
            touchButton = x < 0.33 ? 1 : x > 0.67 ? 2 : 3
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
        }
    }

    private func send(_ action: Int, _ button: Int, coalesced: Bool) {
        let event: [String: Any] = ["action": action, "button": button, "coalesced": coalesced, "deviceSideways": false,
                                    "numberOfTaps": 1, "startMachTime": 0]
        Task { _ = await GuestAgent.rpc("homepod.debug.call", ["operation": "sendButtonCommand:", "arguments": ["event": event]], timeout: 5) }
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
              let rings = geo["rings"] as? [Int], let pixels = s["pixels"] as? [[Double]] else { return }
        var out: [(x: CGFloat, y: CGFloat, ring: Int, color: Color)] = []
        for i in 0..<min(xs.count, ys.count, rings.count, pixels.count) where pixels[i].count >= 3 {
            let p = pixels[i]
            out.append((CGFloat(xs[i]), CGFloat(ys[i]), rings[i], Color(red: p[0] / scale, green: p[1] / scale, blue: p[2] / scale)))
        }
        leds = out
        plus = min(1, ((s["plus"] as? Double) ?? 0) / scale)
        minus = min(1, ((s["minus"] as? Double) ?? 0) / scale)
    }
}
