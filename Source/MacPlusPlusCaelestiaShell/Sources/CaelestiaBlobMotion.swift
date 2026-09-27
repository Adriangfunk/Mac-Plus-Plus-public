import Foundation
import AppKit
import QuartzCore

/// The three values Caelestia's BlobRect keeps for its symmetric 2×2
/// deformation matrix. The implementation deliberately uses the same
/// stiffness, damping, deformation scale, and 35% stretch ceiling as the
/// upstream solver rather than approximating the effect with a scale or an
/// opacity animation.
struct CaelestiaSurfaceDeformation: Equatable {
    var m00: CGFloat = 1
    var m01: CGFloat = 0
    var m11: CGFloat = 1

    static let identity = CaelestiaSurfaceDeformation()

    func affineTransform(around center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .concatenating(CGAffineTransform(a: m00, b: m01, c: m01, d: m11, tx: 0, ty: 0))
            .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
    }
}

/// The direction in which a shell surface's wrapper is travelling. The
/// upstream BlobRect derives this from scene-position velocity; keeping the
/// directions explicit lets the AppKit port feed the same physical model from
/// SwiftUI's attached-surface progress.
enum CaelestiaSurfaceMotionAxis {
    case leading
    case trailing
    case top
    case bottom
    case corner

    var vector: CGVector {
        switch self {
        case .leading: CGVector(dx: 1, dy: 0)
        case .trailing: CGVector(dx: -1, dy: 0)
        case .top: CGVector(dx: 0, dy: -1)
        case .bottom: CGVector(dx: 0, dy: 1)
        case .corner: CGVector(dx: 0.70710678, dy: 0.70710678)
        }
    }
}

/// Native display-synchronised port of Caelestia's BlobRect spring.
///
/// `CADisplayLink` is important here. A SwiftUI timing curve can move a
/// scalar presentation value, but it cannot produce the directional stretch,
/// compression, and settle-back that makes the reference shell feel fluid
/// when a pointer reverses direction halfway through a reveal.
final class CaelestiaBlobMotionDriver: NSObject {
    private let stiffness: CGFloat = 200
    private let damping: CGFloat = 16
    // ContentWindow scales the shell's BlobRect deformation by
    // `(deformAmount * appearance.deformScale) / 10000`. Rail popouts use
    // the default 0.15 amount, so the equivalent Swift value is 0.000015.
    // The old 0.0005 value was the raw BlobRect default rather than the
    // panel's scaled value: a normal handoff therefore hit the 35% stretch
    // cap and pulled the contour away from the fixed shell rim.
    private let deformScale: CGFloat = 0.000015
    private let maximumStretch: CGFloat = 0.35

    private var displayLink: CADisplayLink?
    private var lastSampleTime: CFTimeInterval?
    private var lastSamplePosition: CGPoint?
    private var axis: CaelestiaSurfaceMotionAxis = .leading
    private var travel: CGFloat = 400
    private var active = false

    private var dm00: CGFloat = 1
    private var dm01: CGFloat = 0
    private var dm11: CGFloat = 1
    private var velocity00: CGFloat = 0
    private var velocity01: CGFloat = 0
    private var velocity11: CGFloat = 0

    var onChange: ((CaelestiaSurfaceDeformation) -> Void)?

    var deformation: CaelestiaSurfaceDeformation {
        CaelestiaSurfaceDeformation(m00: dm00, m01: dm01, m11: dm11)
    }

    deinit {
        displayLink?.invalidate()
    }

    func configure(axis: CaelestiaSurfaceMotionAxis, travel: CGFloat) {
        self.axis = axis
        self.travel = max(40, travel)
        lastSampleTime = nil
        lastSamplePosition = nil
    }

    func sample(progress: CGFloat) {
        let direction = axis.vector
        sample(position: CGPoint(
            x: direction.dx * progress * travel,
            y: direction.dy * progress * travel
        ))
    }

    /// Samples the actual scene-space position of the attached shape. QML's
    /// BlobRect does this from the item's moving center, not from a logical
    /// open/closed flag. Reused AppKit popouts have `progress == 1` for their
    /// entire handoff, so frame motion must feed this path directly.
    func sample(position: CGPoint) {
        let now = CACurrentMediaTime()
        guard let previousTime = lastSampleTime, let previousPosition = lastSamplePosition else {
            lastSampleTime = now
            lastSamplePosition = position
            return
        }
        let dt = now - previousTime
        lastSampleTime = now
        lastSamplePosition = position
        guard dt >= 0.001, dt <= 0.1 else { return }

        let velocity = CGVector(
            dx: (position.x - previousPosition.x) / CGFloat(dt),
            dy: (position.y - previousPosition.y) / CGFloat(dt)
        )
        let target = targetMatrix(for: velocity)
        active = true
        startDisplayLink()
        integrate(target: target, dt: min(CGFloat(dt), 1 / 30))
        publish()
    }

    func reset() {
        displayLink?.invalidate()
        displayLink = nil
        lastSampleTime = nil
        lastSamplePosition = nil
        active = false
        dm00 = 1
        dm01 = 0
        dm11 = 1
        velocity00 = 0
        velocity01 = 0
        velocity11 = 0
        publish()
    }

    private func targetMatrix(for velocity: CGVector) -> CaelestiaSurfaceDeformation {
        let speed = hypot(velocity.dx, velocity.dy)
        guard speed > 5 else { return .identity }

        let stretch = 1 + min(speed * deformScale, maximumStretch)
        let compress = 1 / stretch
        let cosA = velocity.dx / speed
        let sinA = velocity.dy / speed
        let cos2 = cosA * cosA
        let sin2 = sinA * sinA
        let cs = cosA * sinA
        return CaelestiaSurfaceDeformation(
            m00: stretch * cos2 + compress * sin2,
            m01: (stretch - compress) * cs,
            m11: stretch * sin2 + compress * cos2
        )
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        guard let link = (NSScreen.main ?? NSScreen.screens.first)?.displayLink(
            target: self,
            selector: #selector(displayLinkFired(_:))
        ) else { return }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard displayLink === link, active else {
            link.invalidate()
            displayLink = nil
            return
        }
        let dt = min(max(CGFloat(link.targetTimestamp - link.timestamp), 1 / 240), 1 / 30)
        integrate(target: .identity, dt: dt)
        publish()

        let totalDelta = abs(dm00 - 1) + abs(dm01) + abs(dm11 - 1)
        let totalVelocity = abs(velocity00) + abs(velocity01) + abs(velocity11)
        if totalDelta < 0.004, totalVelocity < 0.05 {
            active = false
            dm00 = 1
            dm01 = 0
            dm11 = 1
            velocity00 = 0
            velocity01 = 0
            velocity11 = 0
            publish()
            link.invalidate()
            displayLink = nil
        }
    }

    private func integrate(target: CaelestiaSurfaceDeformation, dt: CGFloat) {
        let inverseDamping = 1 / (1 + damping * dt)
        velocity00 = (velocity00 - stiffness * (dm00 - target.m00) * dt) * inverseDamping
        dm00 += velocity00 * dt
        velocity01 = (velocity01 - stiffness * (dm01 - target.m01) * dt) * inverseDamping
        dm01 += velocity01 * dt
        velocity11 = (velocity11 - stiffness * (dm11 - target.m11) * dt) * inverseDamping
        dm11 += velocity11 * dt
    }

    private func publish() {
        onChange?(deformation)
    }
}
