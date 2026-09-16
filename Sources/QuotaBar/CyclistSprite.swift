import AppKit

/// One drawn pose of the menu bar cyclist.
struct CyclistFrame: Hashable, Sendable {
    let cadence: PedalCadence
    let index: Int
    /// Which parked pose is drawn; only consulted when the cadence is `.idle`.
    let parked: ParkedPose

    init(cadence: PedalCadence, index: Int, parked: ParkedPose = .sleeping) {
        self.cadence = cadence
        self.index = index
        self.parked = parked
    }
}

/// Draws the menu bar rider. Parked sits cross-legged with no bike, either asleep or
/// knocking a wooden fish; the three riding cadences come off a single parameterised
/// skeleton, so they stay on model: only the rider's posture, the crank speed and the
/// frame rate differ.
///
/// At 16pt the only things that read are wheel spin, how far the legs swing and how far
/// the torso is folded over the bars, so the riding cadences are separated along those
/// three axes rather than by detail.
enum CyclistSprite {
    /// Crank positions per pedal revolution.
    static let frameCount = 8
    static let size = NSSize(width: 20, height: 22)

    /// How long a frame is held, per cadence. Asleep spends a whole loop on one breath;
    /// the wooden fish gets one strike per loop, at a monk's unhurried tempo.
    static func frameInterval(for cadence: PedalCadence, parked: ParkedPose) -> TimeInterval {
        switch cadence {
        case .idle: return parked == .woodenFish ? 0.15 : 0.45
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
        case .standing: return Posture(lean: 0.95, hipLift: 2.5, hipShift: 1.4, rock: 0.075)
        case .fast: return Posture(lean: 0.78, hipLift: 0.3, hipShift: 0.3, rock: 0)
        default: return Posture(lean: 0.52, hipLift: 0, hipShift: 0, rock: 0)
        }
    }

    // MARK: - Cache

    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ frame: CyclistFrame, tint: NSColor) -> NSImage {
        // Menu bar colours are dynamic: `labelColor` keeps one hash across light and dark,
        // so the cache is keyed on the components it actually resolves to right now, and
        // the sprite is drawn in that same resolved colour.
        let solid = tint.usingColorSpace(.sRGB) ?? tint
        let key = String(format: "%@-%@-%d-%.3f-%.3f-%.3f-%.3f", frame.cadence.rawValue, frame.parked.rawValue,
                         frame.index, solid.redComponent, solid.greenComponent,
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
        guard cadence != .idle else {
            switch frame.parked {
            case .sleeping: return drawSleeper(frameIndex: frame.index, tint: tint)
            case .woodenFish: return drawMonk(frameIndex: frame.index, tint: tint)
            }
        }
        let posture = posture(for: cadence)
        let crank = crankAngle(frameIndex: frame.index)

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

        drawBike(crank: crank, tint: tint)
        // The far leg sits behind the frame, the near leg in front of it.
        drawLeg(crank: crank + .pi, hip: hip, tint: tint.withAlphaComponent(0.38))
        drawRider(hip: hip, shoulder: shoulder, tint: tint)
        drawLeg(crank: crank, hip: hip, tint: tint)

        context.restoreGraphicsState()
    }

    private static func drawBike(crank: CGFloat, tint: NSColor) {
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
        let spin = crank * gearRatio
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

    // MARK: - Sleeping

    /// Parked is asleep: the bike is gone and the rider sits cross-legged facing the
    /// viewer, the upper body rising on each breath and snores drifting off the head.
    ///
    /// Facing out rather than sideways, so the pose reads as its own thing beside the
    /// three left-facing riding cadences, and so the silhouette stays upright — a body
    /// laid flat spans the sprite four points tall and turns to a smudge at 16pt. It is
    /// drawn straight into the sprite's own space, where the riding skeleton's mirror
    /// would have reversed the "z"s.
    private static func drawSleeper(frameIndex: Int, tint: NSColor) {
        let phase = CGFloat(frameIndex) / CGFloat(frameCount)
        // One slow breath per loop, carried by the whole upper body.
        let breath = sin(phase * 2 * .pi) * 0.28

        // The ground is scenery, as faint as the bike it replaces.
        drawLimb([CGPoint(x: 3.6, y: 2.1), CGPoint(x: 16.4, y: 2.1)],
                 width: 0.8, tint: tint.withAlphaComponent(0.42))

        let hip = CGPoint(x: 10.0, y: 5.0 + breath * 0.4)
        let neck = CGPoint(x: 10.0, y: 10.4 + breath)
        let shoulderLeft = CGPoint(x: 7.4, y: 9.7 + breath)
        let shoulderRight = CGPoint(x: 12.6, y: 9.7 + breath)

        // Crossed legs: each shin folds back in under the other, the far one behind.
        drawLimb([hip, CGPoint(x: 14.4, y: 3.9), CGPoint(x: 9.4, y: 2.9)],
                 width: 1.3, tint: tint.withAlphaComponent(0.38))
        drawLimb([hip, CGPoint(x: 5.6, y: 3.9), CGPoint(x: 10.6, y: 2.9)], width: 1.3, tint: tint)

        drawLimb([hip, neck], width: 1.8, tint: tint)
        drawLimb([shoulderLeft, shoulderRight], width: 1.4, tint: tint)
        // The hands come to rest just clear of the knees, so the two do not merge.
        drawLimb([shoulderLeft, CGPoint(x: 5.7, y: 7.3 + breath * 0.5), CGPoint(x: 6.2, y: 5.4)],
                 width: 1.15, tint: tint)
        drawLimb([shoulderRight, CGPoint(x: 14.3, y: 7.3 + breath * 0.5), CGPoint(x: 13.8, y: 5.4)],
                 width: 1.15, tint: tint)

        // Head-on the head carries the pose, so it runs larger than the riding one.
        let headSize = headRadius + 0.65
        let head = CGPoint(x: 10.0, y: 12.4 + breath)
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: head.x - headSize, y: head.y - headSize,
                                    width: headSize * 2, height: headSize * 2)).fill()

        // Two snores in flight at once, half a loop apart. A third one would keep pace
        // close enough to read as one zigzag chain rather than as separate breaths.
        for offset in 0..<2 {
            let travel = (phase + CGFloat(offset) / 2).truncatingRemainder(dividingBy: 1)
            // Each one fades in clear of the head and out below the top of the sprite.
            let fade = min(1, travel / 0.2) * min(1, (1 - travel) / 0.25)
            drawSnore(at: CGPoint(x: 12.9 + travel * 1.4, y: 13.0 + breath + travel * 3.2),
                      size: 1.25 + travel * 1.05, tint: tint.withAlphaComponent(fade))
        }
    }

    // MARK: - Wooden fish

    /// Parked at the wooden fish: the rider sits cross-legged in profile facing left, the
    /// way the riding cadences do, with the fish on the ground in front of the knees and
    /// the near arm swinging a mallet down onto it once a loop. "功德+1" pops above the
    /// scene on the strike and drifts up.
    ///
    /// Built facing left directly in the sprite's own space, so the text is not mirrored.
    /// It runs across the top band, above the head and the raised mallet, because at four
    /// glyphs it needs most of the sprite's width to stay legible at all.
    private static func drawMonk(frameIndex: Int, tint: NSColor) {
        // Swing per frame: raised, falling, strike, then a rebound that settles early so
        // the mallet hangs still before the next strike.
        let swings: [CGFloat] = [0, 0.55, 1, 0.7, 0.35, 0.1, 0, 0]
        let strikeFrame = 2
        let swing = swings[frameIndex % frameCount]

        drawLimb([CGPoint(x: 0.8, y: 2.1), CGPoint(x: 16.4, y: 2.1)],
                 width: 0.8, tint: tint.withAlphaComponent(0.42))

        // The upper body bows forward into the strike.
        let hip = CGPoint(x: 12.6, y: 5.0)
        let neck = CGPoint(x: 12.0 - swing * 0.3, y: 10.3 - swing * 0.3)

        // Legs fold forward under the body, the far one behind and faded.
        drawLimb([hip, CGPoint(x: 9.9, y: 4.1), CGPoint(x: 12.8, y: 2.9)],
                 width: 1.3, tint: tint.withAlphaComponent(0.38))
        // The fish flattens for the one frame the mallet lands.
        drawWoodenFish(centerX: 5.0, squash: max(0, (swing - 0.8) / 0.2), tint: tint)
        drawLimb([hip, CGPoint(x: 9.2, y: 3.7), CGPoint(x: 11.6, y: 2.9)], width: 1.3, tint: tint)
        drawLimb([hip, neck], width: 1.8, tint: tint)

        // A wrist-height tap: the forearm pivots at the elbow from a little above level to
        // pointing down at the fish, and the mallet tips from nose-high to level with it,
        // so the head lands square on the fish's top.
        let elbow = CGPoint(x: 10.2, y: 7.8)
        let forearmAngle = (140 + 55 * swing) * .pi / 180
        let hand = CGPoint(x: elbow.x + cos(forearmAngle) * 2.3, y: elbow.y + sin(forearmAngle) * 2.3)
        let malletAngle = forearmAngle + (25 - 35 * swing) * .pi / 180
        let malletHead = CGPoint(x: hand.x + cos(malletAngle) * 2.4, y: hand.y + sin(malletAngle) * 2.4)
        drawLimb([neck, elbow, hand], width: 1.15, tint: tint)
        drawLimb([hand, malletHead], width: 0.8, tint: tint.withAlphaComponent(0.75))
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: malletHead.x - 0.85, y: malletHead.y - 0.85, width: 1.7, height: 1.7)).fill()

        // The head sits a touch ahead of the neck, looking down at the fish.
        let headSize = headRadius + 0.65
        let head = CGPoint(x: neck.x - 0.3, y: neck.y + 2.0)
        NSBezierPath(ovalIn: NSRect(x: head.x - headSize, y: head.y - headSize,
                                    width: headSize * 2, height: headSize * 2)).fill()

        // Merit pops on the strike and drifts up, gone just before the next one.
        let life = CGFloat((frameIndex - strikeFrame + frameCount) % frameCount) / CGFloat(frameCount)
        let fade = min(1, (life + 0.15) / 0.3) * min(1, (1 - life) / 0.35)
        drawMerit(bottomCenter: CGPoint(x: 10.0, y: 14.2 + life * 1.8), tint: tint.withAlphaComponent(fade))
    }

    /// The wooden fish: a rounded block resting on the ground with its slit cut out, more
    /// solid than the bike since it is what the rider acts on. Squash flattens and widens
    /// it in place, bottom anchored, for the strike.
    private static func drawWoodenFish(centerX: CGFloat, squash: CGFloat, tint: NSColor) {
        let width = 7.2 * (1 + squash * 0.1)
        let height = 5.2 * (1 - squash * 0.15)
        let bottom: CGFloat = 2.4
        let body = NSBezierPath(ovalIn: NSRect(x: centerX - width / 2, y: bottom, width: width, height: height))
        body.windingRule = .evenOdd
        body.appendRoundedRect(NSRect(x: centerX - 2.3, y: bottom + 1.0, width: 4.6, height: 1.1),
                               xRadius: 0.55, yRadius: 0.55)
        tint.withAlphaComponent(0.85).setFill()
        body.fill()
    }

    /// "功德+1", sized to the sprite's width and centred over `bottomCenter`.
    private static func drawMerit(bottomCenter: CGPoint, tint: NSColor) {
        let text = "功德+1" as NSString
        let maxWidth = size.width - 1
        var fontSize: CGFloat = 5.5
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: tint]
        var measured = text.size(withAttributes: attributes)
        if measured.width > maxWidth {
            fontSize *= maxWidth / measured.width
            attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            measured = text.size(withAttributes: attributes)
        }
        text.draw(at: NSPoint(x: bottomCenter.x - measured.width / 2, y: bottomCenter.y), withAttributes: attributes)
    }

    /// One jointed stroke: a leg, an arm, the spine, the ground.
    private static func drawLimb(_ points: [CGPoint], width: CGFloat, tint: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        tint.setStroke()
        path.stroke()
    }

    /// A snore, drawn as the single zig of a "z" and sized to how far it has drifted.
    private static func drawSnore(at origin: CGPoint, size: CGFloat, tint: NSColor) {
        drawLimb([CGPoint(x: origin.x, y: origin.y + size),
                  CGPoint(x: origin.x + size * 0.8, y: origin.y + size),
                  origin,
                  CGPoint(x: origin.x + size * 0.8, y: origin.y)], width: 0.95, tint: tint)
    }
}
