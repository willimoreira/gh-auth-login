import SwiftUI

/// Fundo: grade hexagonal tênue + linha de varredura descendo a tela.
struct HUDBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let r: CGFloat = 18
                let w = sqrt(3) * r
                let h = 1.5 * r
                var grid = Path()
                var row = 0
                var y: CGFloat = 0
                while y < size.height + r {
                    var x: CGFloat = row.isMultiple(of: 2) ? 0 : w / 2
                    while x < size.width + w {
                        for i in 0..<6 {
                            let a = CGFloat(i) * .pi / 3 + .pi / 6
                            let p = CGPoint(x: x + r * cos(a), y: y + r * sin(a))
                            i == 0 ? grid.move(to: p) : grid.addLine(to: p)
                        }
                        grid.closeSubpath()
                        x += w
                    }
                    y += h
                    row += 1
                }
                context.stroke(grid, with: .color(HUD.cyan.opacity(0.05)), lineWidth: 0.5)

                // Linha de varredura.
                let scanY = CGFloat((t * 0.12).truncatingRemainder(dividingBy: 1)) * size.height
                context.fill(
                    Path(CGRect(x: 0, y: scanY - 40, width: size.width, height: 40)),
                    with: .linearGradient(
                        Gradient(colors: [.clear, HUD.cyan.opacity(0.07)]),
                        startPoint: CGPoint(x: 0, y: scanY - 40), endPoint: CGPoint(x: 0, y: scanY)))
            }
        }
        .background(
            RadialGradient(
                colors: [HUD.deep.opacity(0.35), HUD.background], center: .center,
                startRadius: 40, endRadius: 520)
        )
        .ignoresSafeArea()
    }
}

/// Cantoneiras de enquadramento típicas do HUD.
struct CornerBrackets: Shape {
    var length: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = length
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

/// Painel com moldura do HUD.
struct HUDPanel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(HUD.mono(10, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(HUD.cyan.opacity(0.8))
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUD.cyan.opacity(0.04))
        .overlay(CornerBrackets(length: 12).stroke(HUD.cyan.opacity(0.8), lineWidth: 1.5))
        .overlay(Rectangle().stroke(HUD.cyan.opacity(0.15), lineWidth: 0.5))
    }
}

/// Barra superior: identificação, relógio e telemetria do aparelho.
struct StatusBar: View {
    var mode: JarvisAssistant.Mode
    var modelName: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("J.A.R.V.I.S.")
                        .font(HUD.mono(18, weight: .heavy))
                        .tracking(4)
                        .foregroundStyle(HUD.cyan)
                        .glow(HUD.cyan, radius: 6)
                    Text("STARK INDUSTRIES · MK-IV")
                        .font(HUD.mono(9))
                        .tracking(2)
                        .foregroundStyle(HUD.cyan.opacity(0.6))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeline.date, format: .dateTime.hour().minute().second())
                        .font(HUD.mono(16, weight: .semibold))
                        .foregroundStyle(HUD.ice)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(HUD.color(for: mode))
                            .frame(width: 6, height: 6)
                            .glow(HUD.color(for: mode), radius: 4)
                        Text(HUD.label(for: mode))
                            .font(HUD.mono(9, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(HUD.color(for: mode))
                    }
                    Text("\(modelName.uppercased()) · ON-DEVICE · \(batteryText)")
                        .font(HUD.mono(8))
                        .foregroundStyle(HUD.cyan.opacity(0.5))
                }
            }
        }
    }

    private var batteryText: String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? "PWR --" : "PWR \(Int(level * 100))%"
    }
}
