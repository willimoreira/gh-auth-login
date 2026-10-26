import SwiftUI

/// Interface central do J.A.R.V.I.S.: anéis concêntricos girando em velocidades diferentes,
/// marcações de telemetria e um núcleo que pulsa com a voz (sua ou dele).
struct ArcReactorView: View {
    var mode: JarvisAssistant.Mode
    /// 0...1 — nível do microfone ou da fala.
    var energy: Float

    @State private var smoothed: CGFloat = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, time: t)
            }
        }
        .onChange(of: energy) { _, newValue in
            withAnimation(.easeOut(duration: 0.12)) { smoothed = CGFloat(newValue) }
        }
        .onChange(of: mode) { _, _ in
            if energy == 0 { withAnimation(.easeOut(duration: 0.3)) { smoothed = 0 } }
        }
        .aspectRatio(1, contentMode: .fit)
        .glow(HUD.color(for: mode), radius: 18)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) / 2
        let color = HUD.color(for: mode)
        let speed: Double = switch mode {
        case .thinking: 3.2
        case .listening: 1.6
        case .speaking: 1.3
        case .idle: 0.6
        case .offline: 0.25
        }
        let e = smoothed
        let breathe = (sin(t * 1.8) + 1) / 2

        // 1. Anel externo de marcações (360 ticks, maiores a cada 10°).
        for i in 0..<120 {
            let angle = Double(i) / 120 * 2 * .pi + t * 0.05 * speed
            let long = i % 10 == 0
            let r1 = R * 0.97
            let r2 = R * (long ? 0.89 : 0.93)
            var p = Path()
            p.move(to: point(center, r1, angle))
            p.addLine(to: point(center, r2, angle))
            context.stroke(p, with: .color(color.opacity(long ? 0.9 : 0.35)), lineWidth: long ? 2 : 1)
        }

        // 2. Arcos segmentados girando em sentidos opostos.
        ring(&context, center, R * 0.84, width: 3, color: color.opacity(0.85),
             segments: 3, fill: 0.22, rotation: -t * 0.4 * speed)
        ring(&context, center, R * 0.78, width: 1.2, color: color.opacity(0.5),
             segments: 48, fill: 0.55, rotation: t * 0.15 * speed)
        ring(&context, center, R * 0.71, width: 8, color: color.opacity(0.25 + 0.4 * e),
             segments: 6, fill: 0.7, rotation: t * 0.6 * speed)
        ring(&context, center, R * 0.62, width: 2, color: color.opacity(0.9),
             segments: 2, fill: 0.4, rotation: -t * 0.9 * speed)

        // 3. Equalizador radial reagindo à voz.
        let bars = 64
        for i in 0..<bars {
            let angle = Double(i) / Double(bars) * 2 * .pi
            let wave = (sin(Double(i) * 0.9 + t * 9) + sin(Double(i) * 0.37 - t * 5)) / 4 + 0.5
            let amp = CGFloat(wave) * e * R * 0.14 + R * 0.01
            var p = Path()
            p.move(to: point(center, R * 0.53, angle))
            p.addLine(to: point(center, R * 0.53 + amp, angle))
            context.stroke(p, with: .color(color.opacity(0.75)), lineWidth: 2)
        }

        // 4. Triângulo / pentágono interno estilo reator do Mark.
        var shape = Path()
        let sides = 3
        let rot = t * 0.2 * speed
        for i in 0...sides {
            let a = Double(i) / Double(sides) * 2 * .pi + rot - .pi / 2
            let p = point(center, R * 0.45, a)
            i == 0 ? shape.move(to: p) : shape.addLine(to: p)
        }
        context.stroke(shape, with: .color(color.opacity(0.35)), lineWidth: 1.5)
        context.stroke(
            Path(ellipseIn: rect(center, R * 0.45)), with: .color(color.opacity(0.6)), lineWidth: 1)

        // 5. Núcleo luminoso.
        let coreR = R * (0.26 + 0.05 * breathe + 0.12 * e)
        context.fill(
            Path(ellipseIn: rect(center, coreR * 1.6)),
            with: .radialGradient(
                Gradient(colors: [color.opacity(0.35), .clear]),
                center: center, startRadius: coreR * 0.5, endRadius: coreR * 1.6))
        context.fill(
            Path(ellipseIn: rect(center, coreR)),
            with: .radialGradient(
                Gradient(colors: [.white, HUD.ice, color, color.opacity(0.15)]),
                center: center, startRadius: 0, endRadius: coreR))
        context.stroke(
            Path(ellipseIn: rect(center, coreR)), with: .color(.white.opacity(0.8)), lineWidth: 1.5)
    }

    private func ring(
        _ context: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, width: CGFloat,
        color: Color, segments: Int, fill: Double, rotation: Double
    ) {
        let step = 2 * Double.pi / Double(segments)
        for i in 0..<segments {
            let start = Double(i) * step + rotation
            var p = Path()
            p.addArc(
                center: c, radius: r, startAngle: .radians(start),
                endAngle: .radians(start + step * fill), clockwise: false)
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .butt))
        }
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
    }

    private func rect(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }
}
