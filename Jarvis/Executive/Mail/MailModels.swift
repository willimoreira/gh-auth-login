import Foundation

enum MailProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case gmail
    case outlook
    case icloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook / Hotmail / MSN"
        case .icloud: "iCloud Mail"
        }
    }

    var spokenName: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        case .icloud: "iCloud"
        }
    }
}

/// Resumo de um e-mail na lista.
struct MailSummary: Sendable {
    /// Identificador global "<provedor>:<id no provedor>".
    let id: String
    let from: String
    let subject: String
    let date: Date?
    let preview: String
    let unread: Bool
}

/// E-mail completo, pronto para ler em voz alta ou responder.
struct MailMessage: Sendable {
    let id: String
    let from: String
    let fromAddress: String
    let to: [String]
    let subject: String
    let date: Date?
    let body: String
    /// Cabeçalho Message-ID (para respostas encadeadas via SMTP/Gmail).
    var messageID: String?
    /// Conversa (Gmail).
    var threadID: String?
}

/// Uma conta de e-mail conectada.
@MainActor
protocol MailAccount: AnyObject {
    var provider: MailProvider { get }
    var address: String { get }

    func list(query: String?, unreadOnly: Bool, max: Int) async throws -> [MailSummary]
    func read(id: String) async throws -> MailMessage
    func send(to: [String], subject: String, body: String) async throws
    func reply(to message: MailMessage, body: String) async throws
}

enum MailError: LocalizedError {
    case http(Int, String)
    case notFound
    case noAccount
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let detail): "Erro do servidor de e-mail (\(code)): \(detail.prefix(200))"
        case .notFound: "E-mail não encontrado."
        case .noAccount: "Nenhuma conta de e-mail conectada."
        case .invalid(let detail): detail
        }
    }
}

enum MailText {
    /// Converte HTML simples em texto legível (para e-mails sem parte texto).
    static func plain(fromHTML html: String) -> String {
        var text = html
        for (pattern, replacement) in [
            ("(?is)<(script|style)[^>]*>.*?</\\1>", ""),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</p>|</div>|</li>|</tr>", "\n"),
            ("<[^>]+>", ""),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, char) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"),
        ] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return tidy(text)
    }

    /// Remove linhas em branco repetidas e o histórico citado ("> ...", "Em ... escreveu:").
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { continue }
            if line.range(of: "^(Em|On) .+(escreveu|wrote):$", options: .regularExpression) != nil { break }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mensagem RFC 822 simples em UTF-8 (para a API do Gmail).
    static func rfc822(
        from: String, to: [String], subject: String, body: String,
        inReplyTo: String? = nil
    ) -> String {
        var headers = [
            "From: \(from)",
            "To: \(to.joined(separator: ", "))",
            "Subject: =?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?=",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
        ]
        if let inReplyTo {
            headers += ["In-Reply-To: \(inReplyTo)", "References: \(inReplyTo)"]
        }
        let encodedBody = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody
    }

    static func replySubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
    }

    /// Extrai o endereço de "Nome <email@x.com>".
    static func address(in field: String) -> String {
        if let start = field.lastIndex(of: "<"), let end = field.lastIndex(of: ">"), start < end {
            return String(field[field.index(after: start)..<end])
        }
        return field.trimmingCharacters(in: .whitespaces)
    }

    /// Só o nome de "Nome <email@x.com>" (ou o e-mail, se não houver nome).
    static func displayName(in field: String) -> String {
        if let start = field.firstIndex(of: "<") {
            let name = field[..<start].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
        }
        return address(in: field)
    }
}

/// Requisições JSON autenticadas (Gmail e Microsoft Graph).
@MainActor
struct AuthorizedJSON {
    let oauth: OAuthClient

    func get(_ url: URL, headers: [String: String] = [:]) async throws -> [String: Any] {
        try await send(url, method: "GET", body: nil, headers: headers)
    }

    func post(_ url: URL, json: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(url, method: "POST", body: body, headers: ["Content-Type": "application/json"])
    }

    private func send(
        _ url: URL, method: String, body: Data?, headers: [String: String]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(try await oauth.accessToken())", forHTTPHeaderField: "Authorization")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw MailError.http(status, String(decoding: data, as: UTF8.self))
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
