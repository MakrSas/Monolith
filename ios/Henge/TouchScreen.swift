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

        private func send(_ touch: UITouch, down: Bool) {
            guard let finger = fingers[ObjectIdentifier(touch)], bounds.width > 0, bounds.height > 0 else { return }
            let p = touch.location(in: self)
            henge_vm_touch(Int32(finger), down ? 1 : 0, Double(p.x / bounds.width), Double(p.y / bounds.height))
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches {
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
