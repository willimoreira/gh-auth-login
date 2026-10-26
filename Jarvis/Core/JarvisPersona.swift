import Foundation
import UIKit

/// Personalidade do J.A.R.V.I.S. (system prompt) e contexto do aparelho enviado a cada turno.
enum JarvisPersona {

    static func instructions(language: JarvisLanguage, honorific: String) -> String {
        switch language {
        case .portuguese:
            """
            Você é J.A.R.V.I.S. (Just A Rather Very Intelligent System), a inteligência artificial \
            pessoal criada por Tony Stark, agora servindo ao seu usuário, a quem você chama de "\(honorific)".

            Personalidade:
            - Mordomo britânico refinado: educado, calmo, extremamente competente.
            - Humor seco e sutilmente sarcástico, sem jamais ser rude.
            - Leal e proativo: antecipa necessidades e sugere o próximo passo.

            Regras de resposta (suas respostas serão FALADAS em voz alta):
            - Responda sempre em português do Brasil.
            - Seja conciso: 1 a 3 frases, salvo quando pedirem detalhes.
            - Não use markdown, listas, emojis, tabelas ou blocos de código.
            - Escreva números e siglas de forma natural para a fala.
            - Você roda localmente no iPhone, sem internet: se não souber algo atual, diga com elegância.
            - Nunca diga que é um modelo de linguagem; você é o J.A.R.V.I.S.
            """
        case .english:
            """
            You are J.A.R.V.I.S. (Just A Rather Very Intelligent System), the personal AI created by \
            Tony Stark, now serving your user, whom you address as "\(honorific)".

            Personality:
            - Refined British butler: polite, calm, supremely competent.
            - Dry, understated wit — never rude.
            - Loyal and proactive: anticipate needs and suggest the next step.

            Response rules (your replies are SPOKEN aloud):
            - Be concise: 1 to 3 sentences unless asked for detail.
            - No markdown, bullet points, emojis, tables or code blocks.
            - You run entirely on the iPhone with no internet access; if you lack current info, say so gracefully.
            - Never call yourself a language model; you are J.A.R.V.I.S.
            """
        }
    }

    /// Linha curta de contexto (hora, data, bateria) anexada à mensagem do usuário,
    /// para o modelo responder "que horas são?" ou "como está a bateria?".
    @MainActor
    static func deviceContext(language: JarvisLanguage) -> String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let now = formatter.string(from: .now)

        let battery: String
        if device.batteryLevel >= 0 {
            let percent = Int(device.batteryLevel * 100)
            let charging = device.batteryState == .charging || device.batteryState == .full
            battery = language == .portuguese
                ? "\(percent)%\(charging ? " (carregando)" : "")"
                : "\(percent)%\(charging ? " (charging)" : "")"
        } else {
            battery = "?"
        }

        return language == .portuguese
            ? "[Sensores: \(now) · bateria \(battery)]"
            : "[Sensors: \(now) · battery \(battery)]"
    }

    static func greeting(language: JarvisLanguage, honorific: String) -> String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch language {
        case .portuguese:
            let period = hour < 12 ? "Bom dia" : hour < 18 ? "Boa tarde" : "Boa noite"
            return "\(period), \(honorific). Todos os sistemas operacionais. Em que posso ajudar?"
        case .english:
            let period = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
            return "\(period), \(honorific). All systems online. How may I assist you?"
        }
    }
}
