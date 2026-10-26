import Foundation

/// Gmail via API REST oficial (OAuth do Google).
@MainActor
final class GmailAccount: MailAccount {
    let provider = MailProvider.gmail
    private(set) var address: String
    private let api: AuthorizedJSON
    private let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    init(oauth: OAuthClient, address: String) {
        self.api = AuthorizedJSON(oauth: oauth)
        self.address = address
    }

    /// Descobre o endereço da conta logo depois do login.
    static func profileAddress(oauth: OAuthClient) async throws -> String {
        let json = try await AuthorizedJSON(oauth: oauth).get(
            URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        return json["emailAddress"] as? String ?? "Gmail"
    }

    func list(query: String?, unreadOnly: Bool, max: Int) async throws -> [MailSummary] {
        var q = ["in:inbox"]
        if unreadOnly { q.append("is:unread") }
        if let query, !query.isEmpty { q.append(query) }
        var components = URLComponents(string: "\(base)/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: q.joined(separator: " ")),
            URLQueryItem(name: "maxResults", value: String(max)),
        ]
        let list = try await api.get(components.url!)
        let ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }

        var result: [MailSummary] = []
        for id in ids {
            var meta = URLComponents(string: "\(base)/messages/\(id)")!
            meta.queryItems = [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
                URLQueryItem(name: "metadataHeaders", value: "Date"),
            ]
            let message = try await api.get(meta.url!)
            let headers = Self.headers(of: message)
            let labels = message["labelIds"] as? [String] ?? []
            result.append(
                MailSummary(
                    id: "gmail:\(id)",
                    from: MailText.displayName(in: headers["from"] ?? ""),
                    subject: headers["subject"] ?? "(sem assunto)",
                    date: Self.date(of: message),
                    preview: Self.unescape(message["snippet"] as? String ?? ""),
                    unread: labels.contains("UNREAD")))
        }
        return result
    }

    func read(id: String) async throws -> MailMessage {
        var components = URLComponents(string: "\(base)/messages/\(id)")!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        let message = try await api.get(components.url!)
        let headers = Self.headers(of: message)
        let payload = message["payload"] as? [String: Any] ?? [:]

        var body = Self.findBody(in: payload, mime: "text/plain").map(MailText.tidy)
        if body?.isEmpty ?? true {
            body = Self.findBody(in: payload, mime: "text/html").map(MailText.plain(fromHTML:))
        }

        // Marca como lido.
        _ = try? await api.post(
            URL(string: "\(base)/messages/\(id)/modify")!, json: ["removeLabelIds": ["UNREAD"]])

        let from = headers["from"] ?? ""
        return MailMessage(
            id: "gmail:\(id)",
            from: MailText.displayName(in: from),
            fromAddress: MailText.address(in: headers["reply-to"] ?? from),
            to: (headers["to"] ?? "").components(separatedBy: ","),
            subject: headers["subject"] ?? "(sem assunto)",
            date: Self.date(of: message),
            body: body ?? Self.unescape(message["snippet"] as? String ?? ""),
            messageID: headers["message-id"],
            threadID: message["threadId"] as? String)
    }

    func send(to: [String], subject: String, body: String) async throws {
        let raw = MailText.rfc822(from: address, to: to, subject: subject, body: body)
        _ = try await api.post(
            URL(string: "\(base)/messages/send")!,
            json: ["raw": OAuthClient.base64URL(Data(raw.utf8))])
    }

    func reply(to message: MailMessage, body: String) async throws {
        let raw = MailText.rfc822(
            from: address, to: [message.fromAddress],
            subject: MailText.replySubject(message.subject), body: body,
            inReplyTo: message.messageID)
        var json: [String: Any] = ["raw": OAuthClient.base64URL(Data(raw.utf8))]
        if let thread = message.threadID { json["threadId"] = thread }
        _ = try await api.post(URL(string: "\(base)/messages/send")!, json: json)
    }

    // MARK: Parsing

    private static func headers(of message: [String: Any]) -> [String: String] {
        let payload = message["payload"] as? [String: Any] ?? [:]
        var result: [String: String] = [:]
        for header in payload["headers"] as? [[String: Any]] ?? [] {
            if let name = header["name"] as? String, let value = header["value"] as? String {
                result[name.lowercased()] = value
            }
        }
        return result
    }

    private static func date(of message: [String: Any]) -> Date? {
        guard let ms = message["internalDate"] as? String, let value = Double(ms) else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    private static func findBody(in part: [String: Any], mime: String) -> String? {
        if (part["mimeType"] as? String) == mime,
            let data = (part["body"] as? [String: Any])?["data"] as? String,
            let decoded = decodeBase64URL(data)
        {
            return decoded
        }
        for child in part["parts"] as? [[String: Any]] ?? [] {
            if let found = findBody(in: child, mime: mime) { return found }
        }
        return nil
    }

    private static func decodeBase64URL(_ string: String) -> String? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func unescape(_ snippet: String) -> String {
        MailText.plain(fromHTML: snippet)
    }
}
