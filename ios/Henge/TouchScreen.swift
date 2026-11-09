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
