import SwiftUI
import AsteriaKit

/// Welcome-screen backdrop: a drifting starfield over an accent bloom with occasional shooting stars.
/// Freezes when inactive; static under Reduce Motion. All geometry comes from the pure `Starfield` model.
struct StarfieldBackground: View {
    var intensity: Double = 1
    var showShootingStars = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    private let field: Starfield

    init(intensity: Double = 1, showShootingStars: Bool = true) {
        self.intensity = intensity
        self.showShootingStars = showShootingStars
        self.field = Starfield(intensity: intensity)
    }

    var body: some View {
        let paused = reduceMotion || activeState == .inactive
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                drawBloom(context, size: size, t: t, animate: !reduceMotion)
                drawStars(context, size: size, t: t, animate: !reduceMotion)
                if !reduceMotion && showShootingStars, let shot = Starfield.shootingStar(at: t) {
                    drawShootingStar(context, shot, size: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawBloom(_ context: GraphicsContext, size: CGSize, t: Double, animate: Bool) {
        let phase = animate ? sin(t * (2 * .pi / 16)) : 0          // ~16s breath
        let r = max(size.width, size.height) * 0.58 * (1 + 0.06 * phase)
        let o = (0.16 + 0.03 * phase) * intensity
        let c = CGPoint(x: Starfield.bloomCenter.x * size.width, y: Starfield.bloomCenter.y * size.height)
        let grad = Gradient(stops: [
            .init(color: AsteriaTheme.accent.opacity(o), location: 0),
            .init(color: AsteriaTheme.accent.opacity(o * 0.4), location: 0.4),
            .init(color: .clear, location: 1),
        ])
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(grad, center: c, startRadius: 0, endRadius: r))
    }

    private func drawStars(_ context: GraphicsContext, size: CGSize, t: Double, animate: Bool) {
        for star in field.stars {
            let p = field.position(of: star, at: t)
            let alpha = field.alpha(of: star, at: t, animate: animate)
            let rect = CGRect(x: p.x * size.width - star.size / 2,
                              y: p.y * size.height - star.size / 2,
                              width: star.size, height: star.size)
            context.fill(Path(ellipseIn: rect), with: .color(color(star.tint).opacity(alpha)))
        }
    }

    private func drawShootingStar(_ context: GraphicsContext, _ shot: ShootingStar, size: CGSize) {
        let head = CGPoint(x: shot.headX * size.width, y: shot.headY * size.height)
        let tail = CGPoint(x: shot.tailX * size.width, y: shot.tailY * size.height)
        var path = Path(); path.move(to: tail); path.addLine(to: head)
        context.stroke(path,
                       with: .linearGradient(Gradient(colors: [.clear, Color.white.opacity(shot.alpha)]),
                                             startPoint: tail, endPoint: head),
                       lineWidth: 1.3)
    }

    private func color(_ tint: StarTint) -> Color {
        switch tint {
        case .accent: return AsteriaTheme.accent
        case .blueWhite: return Color(red: 0.74, green: 0.82, blue: 1.0)
        case .white: return .white
        }
    }
}
