import AppKit

/// One drawn pose of the menu bar cyclist.
struct CyclistFrame: Hashable, Sendable {
    let cadence: PedalCadence
    let index: Int
}

/// Draws the menu bar cyclist from a single parameterised skeleton, so all four cadences
/// stay on model: only the rider's posture, the crank speed and the frame rate differ.
///
/// At 16pt the only things that read are wheel spin, how far the legs swing and how far
/// the torso is folded over the bars, so the cadences are separated along those three
/// axes rather than by detail.
enum CyclistSprite {
    /// Crank positions per pedal revolution.
    static let frameCount = 8
    static let size = NSSize(width: 20, height: 22)

    /// Milliseconds a frame is held, per cadence.
    static func frameInterval(for cadence: PedalCadence) -> TimeInterval {
        switch cadence {
        case .idle: return .infinity
        case .normal: return 0.125
        case .fast: return 0.070
        case .standing: return 0.050
        }
    }

    // MARK: - Geometry

    private static let wheelRadius: CGFloat = 2.9
    private static let rearHub = CGPoint(x: 4.3, y: 4.3)
    private static let frontHub = CGPoint(x: 15.7, y: 4.3)
    private static let bottomBracket = CGPoint(x: 10.0, y: 5.4)
    private static let crankRadius: CGFloat = 2.2
    private static let saddle = CGPoint(x: 6.9, y: 11.4)
    private static let handlebar = CGPoint(x: 15.0, y: 10.4)
    private static let thigh: CGFloat = 3.9
    private static let shin: CGFloat = 4.4
    private static let torso: CGFloat = 5.4
    private static let headRadius: CGFloat = 1.25
    /// Wheel turns faster than the crank, the way a drivetrain gears up.
    private static let gearRatio: CGFloat = 2.4

    /// Posture per cadence: how far the torso folds, how far the rider lifts off the
    /// saddle, and how much the bike rocks side to side.
    private struct Posture {
        let lean: CGFloat
        let hipLift: CGFloat
        let hipShift: CGFloat
        let rock: CGFloat
    }

    private static func posture(for cadence: PedalCadence) -> Posture {
        switch cadence {
        case .idle: return Posture(lean: 0.36, hipLift: 0, hipShift: 0, rock: 0)
        case .normal: return Posture(lean: 0.52, hipLift: 0, hipShift: 0, rock: 0)
        case .fast: return Posture(lean: 0.78, hipLift: 0.3, hipShift: 0.3, rock: 0)
        case .standing: return Posture(lean: 0.95, hipLift: 2.5, hipShift: 1.4, rock: 0.075)
        }
    }

    // MARK: - Cache

    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ frame: CyclistFrame, tint: NSColor) -> NSImage {
        // Menu bar colours are dynamic: `labelColor` keeps one hash across light and dark,
        // so the cache is keyed on the components it actually resolves to right now, and
        // the sprite is drawn in that same resolved colour.
        let solid = tint.usingColorSpace(.sRGB) ?? tint
        let key = String(format: "%@-%d-%.3f-%.3f-%.3f-%.3f", frame.cadence.rawValue, frame.index,
                         solid.redComponent, solid.greenComponent,
                         solid.blueComponent, solid.alphaComponent) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = rendered(frame, tint: solid, scale: 2)
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Rendering

    /// Uncached render at an arbitrary scale, for previews and settings artwork.
    static func rendered(_ frame: CyclistFrame, tint: NSColor, scale: CGFloat) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage(size: size)
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(frame, tint: tint)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func draw(_ frame: CyclistFrame, tint: NSColor) {
        let cadence = frame.cadence
        let posture = posture(for: cadence)
        // Idle parks the cranks level, one foot down.
        let crank = cadence == .idle ? Self.parkedCrank : crankAngle(frameIndex: frame.index)

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        // The skeleton is built facing right and mirrored once here, which also flips the
        // handedness of the crank and wheel rotation to match a rider heading left.
        let mirror = NSAffineTransform()
        mirror.translateX(by: size.width, yBy: 0)
        mirror.scaleX(by: -1, yBy: 1)
        mirror.concat()
        // Out of the saddle the bike rocks under the rider.
        if posture.rock != 0 {
            let pivot = NSPoint(x: 10, y: 3)
            let transform = NSAffineTransform()
            transform.translateX(by: pivot.x, yBy: pivot.y)
            transform.rotate(byRadians: sin(crank) * posture.rock)
            transform.translateX(by: -pivot.x, yBy: -pivot.y)
            transform.concat()
        }

        let hip = CGPoint(x: saddle.x + posture.hipShift, y: saddle.y + posture.hipLift)
        let shoulder = CGPoint(x: hip.x + sin(posture.lean) * torso,
                               y: hip.y + cos(posture.lean) * torso)

        drawBike(crank: crank, cadence: cadence, tint: tint)
        // The far leg sits behind the frame, the near leg in front of it.
        drawLeg(crank: crank + .pi, hip: hip, tint: tint.withAlphaComponent(0.38))
        drawRider(hip: hip, shoulder: shoulder, tint: tint)
        drawLeg(crank: crank, hip: hip, tint: tint)

        context.restoreGraphicsState()
    }

    private static func drawBike(crank: CGFloat, cadence: PedalCadence, tint: NSColor) {
        // The bike is scenery: thin and faded, so the rider stays the subject.
        let frameColor = tint.withAlphaComponent(0.42)

        let chassis = NSBezierPath()
        chassis.lineWidth = 0.7
        chassis.lineCapStyle = .round
        chassis.lineJoinStyle = .round
        for (from, to) in [(rearHub, bottomBracket), (bottomBracket, saddle),
                           (saddle, handlebar), (handlebar, frontHub)] {
            chassis.move(to: from)
            chassis.line(to: to)
        }
        frameColor.setStroke()
        chassis.stroke()

        // Two spokes per wheel: enough for the eye to track rotation, few enough that
        // they do not blur into a grey disc at 16pt.
        let spin = cadence == .idle ? 0 : crank * gearRatio
        for hub in [rearHub, frontHub] {
            let rim = NSBezierPath(ovalIn: NSRect(x: hub.x - wheelRadius, y: hub.y - wheelRadius,
                                                  width: wheelRadius * 2, height: wheelRadius * 2))
            rim.lineWidth = 0.85
            tint.withAlphaComponent(0.75).setStroke()
            rim.stroke()

            let spokes = NSBezierPath()
            spokes.lineWidth = 0.55
            for index in 0..<2 {
                let angle = spin + .pi / 6 + CGFloat(index) * .pi / 2
                let reach = wheelRadius - 0.3
                spokes.move(to: CGPoint(x: hub.x + cos(angle) * reach, y: hub.y + sin(angle) * reach))
                spokes.line(to: CGPoint(x: hub.x - cos(angle) * reach, y: hub.y - sin(angle) * reach))
            }
            frameColor.setStroke()
            spokes.stroke()
        }

        let arm = NSBezierPath()
        arm.lineWidth = 0.7
        arm.lineCapStyle = .round
        arm.move(to: pedal(crank: crank))
        arm.line(to: pedal(crank: crank + .pi))
        frameColor.setStroke()
        arm.stroke()
    }

    /// Crank angle for a frame, in the right-facing space the skeleton is built in:
    /// a forward-rolling wheel turns clockwise there, which is negative, and the mirror
    /// applied at draw time turns it into the left-facing rotation on screen. Getting the
    /// sign wrong pedals the rider backwards.
    static func crankAngle(frameIndex: Int) -> CGFloat {
        -CGFloat(frameIndex) / CGFloat(frameCount) * 2 * .pi
    }

    /// Where the parked rider leaves the cranks: level, one foot down.
    static let parkedCrank: CGFloat = .pi / 2

    static func pedal(crank: CGFloat) -> CGPoint {
        CGPoint(x: bottomBracket.x + cos(crank) * crankRadius,
                y: bottomBracket.y + sin(crank) * crankRadius)
    }

    private static func drawRider(hip: CGPoint, shoulder: CGPoint, tint: NSColor) {
        tint.setStroke()
        let body = NSBezierPath()
        body.lineWidth = 1.4
        body.lineCapStyle = .round
        body.move(to: hip)
        body.line(to: shoulder)
        body.stroke()

        let arm = NSBezierPath()
        arm.lineWidth = 0.95
        arm.lineCapStyle = .round
        arm.move(to: shoulder)
        arm.line(to: handlebar)
        arm.stroke()

        // The head carries on along the spine, clear of the shoulder so the two do not
        // merge into one blob.
        let spine = CGPoint(x: shoulder.x - hip.x, y: shoulder.y - hip.y)
        let length = max(0.001, sqrt(spine.x * spine.x + spine.y * spine.y))
        let center = CGPoint(x: shoulder.x + spine.x / length * (headRadius + 0.75),
                             y: shoulder.y + spine.y / length * (headRadius + 0.75))
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - headRadius, y: center.y - headRadius,
                                    width: headRadius * 2, height: headRadius * 2)).fill()
    }

    /// Two-link solve: the ankle rides the crank circle, the hip is fixed, and the knee
    /// falls out of the triangle between them. Of the two solutions the knee takes the
    /// one ahead of the hip-to-ankle line, which is the way a knee bends.
    private static func drawLeg(crank: CGFloat, hip: CGPoint, tint: NSColor) {
        let ankle = pedal(crank: crank)
        let span = CGPoint(x: ankle.x - hip.x, y: ankle.y - hip.y)
        let distance = min(thigh + shin - 0.01, max(abs(thigh - shin) + 0.01,
                                                    sqrt(span.x * span.x + span.y * span.y)))
        let base = atan2(span.y, span.x)
        let cosine = (thigh * thigh + distance * distance - shin * shin) / (2 * thigh * distance)
        let bend = acos(min(1, max(-1, cosine)))
        let kneeAngle = base + bend
        let knee = CGPoint(x: hip.x + cos(kneeAngle) * thigh, y: hip.y + sin(kneeAngle) * thigh)

        let leg = NSBezierPath()
        leg.lineWidth = 1.25
        leg.lineCapStyle = .round
        leg.lineJoinStyle = .round
        leg.move(to: hip)
        leg.line(to: knee)
        leg.line(to: ankle)
        tint.setStroke()
        leg.stroke()
    }
}
