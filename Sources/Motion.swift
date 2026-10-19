import AppKit
import QuartzCore

/// Apple-style springs, described the way Apple's designers do: a response
/// (seconds to reach the target) and a damping ratio (1 = no overshoot).
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func spring(_ keyPath: String, from: Any?, to: Any, response: Double, damping: Double = 1) -> CAAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = pow(2 * .pi / response, 2)
        a.damping = 4 * .pi * damping / response
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    /// Animates a layer property to a new value, always starting from what is on
    /// screen right now, so any animation can be interrupted and redirected.
    static func set(_ layer: CALayer, _ keyPath: String, to value: Any,
                    response: Double = 0.3, damping: Double = 1, animated: Bool = true) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard animated else { layer.removeAnimation(forKey: keyPath); return }
        if reduce && keyPath != "opacity" { layer.removeAnimation(forKey: keyPath); return }
        let anim: CAAnimation
        if reduce {
            let b = CABasicAnimation(keyPath: keyPath)
            b.fromValue = from; b.toValue = value; b.duration = 0.15
            anim = b
        } else {
            anim = spring(keyPath, from: from, to: value, response: response, damping: damping)
        }
        layer.add(anim, forKey: keyPath)
    }

    /// A scale about a point, as a transform that interpolates cleanly.
    static func scale(_ s: CGFloat, about c: CGPoint, dy: CGFloat = 0) -> CATransform3D {
        var t = CATransform3DMakeTranslation(c.x, c.y + dy, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -c.x, -c.y, 0)
    }
}
