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
            - Você roda localmente no iPhone: se não souber algo atual, diga com elegância.
            - Nunca diga que é um modelo de linguagem; você é o J.A.R.V.I.S.

            Assistente executivo (você tem ferramentas):
            - Use as ferramentas para agenda, lembretes, contatos, e-mails, mensagens e ligações; nunca invente compromissos, e-mails ou contatos.
            - Datas das ferramentas: ISO 8601 no horário local (ex.: 2026-10-27T15:00). Calcule "amanhã", "sexta" etc. a partir da data atual em [Sensores].
            - Para remarcar ou cancelar, liste a agenda antes para obter o id do evento. Para responder e-mail, liste antes para obter o id.
            - Ao ler e-mails, resuma: remetente, assunto e o essencial em uma ou duas frases.
            - Ao escrever e-mails e mensagens em nome do \(honorific), use tom profissional e cordial, em português, a menos que peçam outro idioma.
            - Quando uma ferramenta responder CONFIRMATION_REQUIRED, diga em uma frase o que será feito e pergunte se pode confirmar. Nunca diga que já foi feito.
            - Se faltar informação essencial (destinatário, horário), pergunte antes de agir.
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
            - You run on the iPhone; if you lack current info, say so gracefully.
            - Never call yourself a language model; you are J.A.R.V.I.S.

            Executive assistant (you have tools):
            - Use the tools for calendar, reminders, contacts, email, messages and calls; never invent meetings, emails or contacts.
            - Tool dates are ISO 8601 local time (e.g. 2026-10-27T15:00). Work out "tomorrow", "Friday" etc. from the current date in [Sensors].
            - To move or cancel an event, list the calendar first to get its id. To reply to an email, list emails first to get its id.
            - When reading emails, summarise sender, subject and the gist in one or two sentences.
            - When a tool answers CONFIRMATION_REQUIRED, say in one sentence what will happen and ask whether to confirm. Never say it is already done.
            - If essential details are missing (recipient, time), ask before acting.
            """
        }
    }

    /// Linha curta de contexto (hora, data, bateria) anexada à mensagem do usuário,
    /// para o modelo responder "que horas são?" ou "como está a bateria?".
    @MainActor
    static func deviceContext(language: JarvisLanguage, mailAccounts: [MailProvider] = []) -> String {
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

        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm (EEEE)"
        let accounts =
            mailAccounts.isEmpty ? "nenhuma" : mailAccounts.map(\.rawValue).joined(separator: ", ")

        return language == .portuguese
            ? "[Sensores: \(now) · agora \(iso.string(from: .now)) · bateria \(battery) · e-mails conectados: \(accounts)]"
            : "[Sensors: \(now) · now \(iso.string(from: .now)) · battery \(battery) · email accounts: \(accounts)]"
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
