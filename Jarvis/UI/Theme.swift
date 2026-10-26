import SwiftUI

enum HUD {
    static let cyan = Color(red: 0.0, green: 0.85, blue: 1.0)
    static let ice = Color(red: 0.75, green: 0.95, blue: 1.0)
    static let deep = Color(red: 0.0, green: 0.35, blue: 0.55)
    static let amber = Color(red: 1.0, green: 0.68, blue: 0.15)
    static let red = Color(red: 1.0, green: 0.25, blue: 0.2)
    static let background = Color(red: 0.01, green: 0.03, blue: 0.06)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func color(for mode: JarvisAssistant.Mode) -> Color {
        switch mode {
        case .offline: deep
        case .idle, .standby: cyan
        case .listening: ice
        case .thinking: amber
        case .speaking: cyan
        }
    }

    static func label(for mode: JarvisAssistant.Mode) -> String {
        switch mode {
        case .offline: "INICIALIZANDO"
        case .idle: "EM ESPERA"
        case .standby: "PRONTO · DIGA JARVIS"
        case .listening: "OUVINDO"
        case .thinking: "PROCESSANDO"
        case .speaking: "RESPONDENDO"
        }
    }
}

extension View {
    /// Brilho neon característico do HUD.
    func glow(_ color: Color, radius: CGFloat = 8) -> some View {
        shadow(color: color.opacity(0.9), radius: radius / 2)
            .shadow(color: color.opacity(0.5), radius: radius)
    }
}
