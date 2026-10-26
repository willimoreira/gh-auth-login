import Foundation

/// Outlook / Hotmail / MSN / Live via Microsoft Graph.
@MainActor
final class OutlookAccount: MailAccount {
    let provider = MailProvider.outlook
    private(set) var address: String
    private let api: AuthorizedJSON
    private let base = "https://graph.microsoft.com/v1.0/me"

    init(oauth: OAuthClient, address: String) {
        self.api = AuthorizedJSON(oauth: oauth)
        self.address = address
    }

    static func profileAddress(oauth: OAuthClient) async throws -> String {
        let json = try await AuthorizedJSON(oauth: oauth).get(
            URL(string: "https://graph.microsoft.com/v1.0/me")!)
        return json["mail"] as? String ?? json["userPrincipalName"] as? String ?? "Outlook"
    }

    func list(query: String?, unreadOnly: Bool, max: Int) async throws -> [MailSummary] {
        var components = URLComponents(string: "\(base)/mailFolders/inbox/messages")!
        var items = [
            URLQueryItem(name: "$top", value: String(max)),
            URLQueryItem(name: "$select", value: "id,subject,from,receivedDateTime,bodyPreview,isRead"),
        ]
        if let query, !query.isEmpty {
            // $search não aceita $filter/$orderby junto; filtramos "não lidos" localmente.
            items.append(URLQueryItem(name: "$search", value: "\"\(query.replacingOccurrences(of: "\"", with: ""))\""))
        } else {
            items.append(URLQueryItem(name: "$orderby", value: "receivedDateTime desc"))
            if unreadOnly { items.append(URLQueryItem(name: "$filter", value: "isRead eq false")) }
        }
        components.queryItems = items

        let json = try await api.get(components.url!)
        return (json["value"] as? [[String: Any]] ?? []).compactMap { message in
            guard let id = message["id"] as? String else { return nil }
            let unread = !(message["isRead"] as? Bool ?? true)
            if unreadOnly, !unread { return nil }
            return MailSummary(
                id: "outlook:\(id)",
                from: Self.sender(message).name,
                subject: message["subject"] as? String ?? "(sem assunto)",
                date: Self.date(message["receivedDateTime"]),
                preview: message["bodyPreview"] as? String ?? "",
                unread: unread)
        }
    }

    func read(id: String) async throws -> MailMessage {
        var components = URLComponents(string: "\(base)/messages/\(id)")!
        components.queryItems = [
            URLQueryItem(
                name: "$select",
                value: "id,subject,from,toRecipients,receivedDateTime,body,internetMessageId,conversationId")
        ]
        let message = try await api.get(
            components.url!, headers: ["Prefer": "outlook.body-content-type=\"text\""])

        // Marca como lido.
        try? await markRead(id: id)

        let sender = Self.sender(message)
        let body = (message["body"] as? [String: Any])?["content"] as? String ?? ""
        let to = (message["toRecipients"] as? [[String: Any]] ?? []).compactMap {
            ($0["emailAddress"] as? [String: Any])?["address"] as? String
        }
        return MailMessage(
            id: "outlook:\(id)",
            from: sender.name,
            fromAddress: sender.address,
            to: to,
            subject: message["subject"] as? String ?? "(sem assunto)",
            date: Self.date(message["receivedDateTime"]),
            body: MailText.tidy(body),
            messageID: message["internetMessageId"] as? String,
            threadID: message["conversationId"] as? String)
    }

    func send(to: [String], subject: String, body: String) async throws {
        _ = try await api.post(
            URL(string: "\(base)/sendMail")!,
            json: [
                "message": [
                    "subject": subject,
                    "body": ["contentType": "Text", "content": body],
                    "toRecipients": to.map { ["emailAddress": ["address": $0]] },
                ],
                "saveToSentItems": true,
            ])
    }

    func reply(to message: MailMessage, body: String) async throws {
        let rawID = String(message.id.dropFirst("outlook:".count))
        _ = try await api.post(URL(string: "\(base)/messages/\(rawID)/reply")!, json: ["comment": body])
    }

    private func markRead(id: String) async throws {
        var request = URLRequest(url: URL(string: "\(base)/messages/\(id)")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await api.oauth.accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["isRead": true])
        _ = try await URLSession.shared.data(for: request)
    }

    private static func sender(_ message: [String: Any]) -> (name: String, address: String) {
        let email = (message["from"] as? [String: Any])?["emailAddress"] as? [String: Any] ?? [:]
        let address = email["address"] as? String ?? ""
        let name = email["name"] as? String ?? address
        return (name.isEmpty ? address : name, address)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}
