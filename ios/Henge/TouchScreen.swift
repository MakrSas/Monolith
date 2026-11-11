import SwiftUI
import UIKit

/// The guest's screen as a touch screen, for vresearch101 guests (watchOS, iOS): each finger on the
/// picture is a finger on the guest's USB touch screen, at the same place (up to four at once).
struct TouchScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {}

    final class Surface: UIView {
        private var fingers: [ObjectIdentifier: Int] = [:]

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError() }

        /// A touch that started at an edge of the screen: it goes through the guest agent with the
        /// digitizer's edge flag, which the USB touch screen's report has no room for and without which
        /// the guest's edge gestures (Control Center, Home) never start. vphone does the same.
        private var edgeTouch: (id: ObjectIdentifier, edge: Int)?
        private let edgeQueue = EdgeTouchQueue()

        private func point(_ touch: UITouch) -> (Double, Double) {
            let p = touch.location(in: self)
            return (min(max(Double(p.x / bounds.width), 0), 1), min(max(Double(p.y / bounds.height), 0), 1))
        }

        /// 1 top, 2 bottom, 4 right, 8 left (vphone's encoding), 0 inside.
        private func edge(at x: Double, _ y: Double) -> Int {
            let mx = 22 / Double(bounds.width), my = 22 / Double(bounds.height) // about a fingertip
            if y < my { return 1 }
            if y > 1 - my { return 2 }
            if x > 1 - mx { return 4 }
            if x < mx { return 8 }
            return 0
        }

        private func send(_ touch: UITouch, down: Bool) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            if let e = edgeTouch, e.id == ObjectIdentifier(touch) {
                let (x, y) = point(touch)
                edgeQueue.send(phase: down ? "move" : "up", x: x, y: y, edge: e.edge)
                return
            }
            guard let finger = fingers[ObjectIdentifier(touch)] else { return }
            let (x, y) = point(touch)
            henge_vm_screen_touch(Int32(finger), down ? 1 : 0, x, y)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches {
                if bounds.width > 0, edgeTouch == nil, fingers.isEmpty {
                    let (x, y) = point(t)
                    let e = edge(at: x, y)
                    if e != 0 {
                        edgeTouch = (ObjectIdentifier(t), e)
                        edgeQueue.send(phase: "down", x: x, y: y, edge: e)
                        continue
                    }
                }
                guard let free = (0..<4).first(where: { !fingers.values.contains($0) }) else { break }
                fingers[ObjectIdentifier(t)] = free
                send(t, down: true)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { send(t, down: true) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches {
                send(t, down: false)
                if edgeTouch?.id == ObjectIdentifier(t) { edgeTouch = nil }
                fingers[ObjectIdentifier(t)] = nil
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
    }
}

/// A hardware button of the guest device, held while pressed: 0 Home (the Digital Crown on a watch),
/// 1 a watch's side button, 2 volume up, 3 volume down, 4 power (sleep and wake).
struct DeviceButton: View {
    let symbol: String
    let label: String
    let button: Int32
    @State private var held = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium))
            Text(label).font(.system(size: 12))
        }
        .foregroundStyle(held ? Desk.accentLight : .white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !held { held = true; henge_vm_button(button, 1) }
            }
            .onEnded { _ in
                held = false
                henge_vm_button(button, 0)
            })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The Digital Crown: drag up or down on it to turn it, one detent every few points with a click
/// of the Taptic Engine for each (faster turns click faster, as the real crown does); tap or hold it
/// to press it (Home).
struct DigitalCrown: View {
    /// Points of drag per detent.
    private let step: CGFloat = 9
    @State private var lastY: CGFloat?
    @State private var carried: CGFloat = 0
    @State private var turned = false
    @State private var pressed = false
    @State private var angle: Double = 0
    private let detent = UISelectionFeedbackGenerator()
    private let press = UIImpactFeedbackGenerator(style: .rigid)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22), Color(white: 0.42)],
                                     startPoint: .leading, endPoint: .trailing))
            // Knurling that moves with the turn.
            Canvas { ctx, size in
                let pitch: CGFloat = 5
                let offset = CGFloat(angle.truncatingRemainder(dividingBy: Double(pitch)))
                var y = offset - pitch
                while y < size.height + pitch {
                    ctx.fill(Path(CGRect(x: 4, y: y, width: size.width - 8, height: 1.2)), with: .color(.white.opacity(0.28)))
                    y += pitch
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(width: 34)
        .scaleEffect(pressed ? 0.94 : 1)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if lastY == nil {
                    lastY = g.location.y
                    turned = false
                    detent.prepare()
                    press.prepare()
                    // A press that does not turn: Home goes down at once, as on the watch.
                    pressed = true
                    henge_vm_button(0, 1)
                    return
                }
                let dy = (lastY ?? g.location.y) - g.location.y
                lastY = g.location.y
                carried += dy
                angle += Double(dy)
                var n = 0
                while carried >= step { carried -= step; n += 1 }
                while carried <= -step { carried += step; n -= 1 }
                if n != 0 {
                    if !turned {
                        turned = true
                        if pressed { pressed = false; henge_vm_button(0, 0) } // it was a turn, not a press
                    }
                    henge_vm_crown(Int32(n))
                    for _ in 0..<min(abs(n), 3) { detent.selectionChanged() }
                    detent.prepare()
                }
            }
            .onEnded { _ in
                if pressed {
                    press.impactOccurred()
                    henge_vm_button(0, 0)
                }
                pressed = false
                lastY = nil
                carried = 0
            })
        .animation(.easeOut(duration: 0.08), value: pressed)
        .accessibilityLabel("Digital Crown")
        .accessibilityAdjustableAction { dir in
            henge_vm_crown(dir == .increment ? 1 : -1)
            detent.selectionChanged()
        }
    }
}

/// A TV remote for tvOS guests: a click pad (swipe to move, tap to select), Back, TV/Home and Play/Pause.
/// The pad's moves and Select are the keyboard's arrows and Return, Back its Escape, as vphone's remote is.
struct TVRemote: View {
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    @State private var start: CGPoint?

    private func key(_ usage: UInt8) {
        henge_vm_key_hid(usage, 1)
        henge_vm_key_hid(usage, 0)
        feedback.impactOccurred()
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color(white: 0.16))
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
                Image(systemName: "circle.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.25))
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in if start == nil { start = g.startLocation } }
                .onEnded { g in
                    let dx = g.translation.width, dy = g.translation.height
                    start = nil
                    if max(abs(dx), abs(dy)) < 18 { key(0x28); return } // tap: Select
                    if abs(dx) > abs(dy) { key(dx > 0 ? 0x4f : 0x50) } else { key(dy > 0 ? 0x51 : 0x52) }
                })
            .accessibilityLabel("Touch surface: swipe to move, tap to select")
            VStack(spacing: 10) {
                remoteButton("chevron.backward", "Back") { key(0x29) }
                remoteButton("tv", "TV") { henge_vm_button(0, 1); henge_vm_button(0, 0) }
                remoteButton("playpause.fill", "Play/Pause") { henge_vm_button(5, 1); henge_vm_button(5, 0) }
            }
        }
        .padding(12)
    }

    private func remoteButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 52, height: 52).background(Color(white: 0.2), in: Circle())
        }
        .accessibilityLabel(label)
    }
}


/// Edge touches to the guest agent one after another, in order: a move may not overtake its down.
/// Moves that pile up while one is on its way are merged into the newest.
final class EdgeTouchQueue {
    private var pending: [(phase: String, x: Double, y: Double, edge: Int)] = []
    private var running = false

    func send(phase: String, x: Double, y: Double, edge: Int) {
        if phase == "move", let last = pending.last, last.phase == "move" { pending.removeLast() }
        pending.append((phase, x, y, edge))
        guard !running else { return }
        running = true
        Task { @MainActor in
            while !self.pending.isEmpty {
                let t = self.pending.removeFirst()
                _ = await GuestAgent.rpc("input.touch", ["phase": t.phase, "x": t.x, "y": t.y, "normalized": true, "edge": t.edge], timeout: 3)
            }
            self.running = false
        }
    }
}
