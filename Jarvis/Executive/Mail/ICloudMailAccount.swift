import Foundation
import SwiftMail

/// iCloud Mail via IMAP/SMTP com uma **senha de app** (appleid.apple.com › Senhas de app).
@MainActor
final class ICloudMailAccount: MailAccount {
    let provider = MailProvider.icloud
    let address: String
    private let password: String

    init(address: String, appPassword: String) {
        self.address = address
        self.password = appPassword
    }

    /// Testa as credenciais (usado ao conectar a conta).
    func verify() async throws {
        let imap = try await openInbox()
        try? await imap.logout()
    }

    func list(query: String?, unreadOnly: Bool, max: Int) async throws -> [MailSummary] {
        let imap = try await openInbox()
        defer { Task { try? await imap.logout() } }

        var criteria: [SearchCriteria] = []
        if unreadOnly { criteria.append(.unseen) }
        if let query, !query.isEmpty { criteria.append(.text(query)) }
        if criteria.isEmpty { criteria.append(.all) }

        let found: UIDSet = try await imap.search(criteria: criteria)
        let latest = found.toArray().sorted { $0.value > $1.value }.prefix(max)
        guard !latest.isEmpty else { return [] }
        var wanted = UIDSet()
        latest.forEach { wanted.insert($0) }

        var result: [MailSummary] = []
        for try await info in imap.fetchMessageInfos(using: wanted) {
            guard let uid = info.uid else { continue }
            result.append(
                MailSummary(
                    id: "icloud:\(uid.value)",
                    from: Self.name(info.fromAddresses),
                    subject: info.subject ?? "(sem assunto)",
                    date: info.date,
                    preview: "",
                    unread: !info.flags.contains(.seen)))
        }
        return result.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    func read(id: String) async throws -> MailMessage {
        guard let value = UInt32(id) else { throw MailError.notFound }
        let imap = try await openInbox()
        defer { Task { try? await imap.logout() } }

        var set = UIDSet()
        set.insert(UID(value))
        var fetched: Message?
        for try await message in imap.fetchMessages(using: set) {
            fetched = message
            break
        }
        guard let message = fetched else { throw MailError.notFound }
        try? await imap.store(flags: [.seen], on: set, operation: .add)

        let body =
            message.textBody.map(MailText.tidy)
            ?? message.htmlBody.map(MailText.plain(fromHTML:)) ?? ""
        let replyTo = message.replyToAddresses.isEmpty ? message.fromAddresses : message.replyToAddresses
        return MailMessage(
            id: "icloud:\(value)",
            from: Self.name(message.fromAddresses),
            fromAddress: Self.addresses(replyTo).first ?? "",
            to: Self.addresses(message.toAddresses),
            subject: message.subject ?? "(sem assunto)",
            date: message.date,
            body: body,
            messageID: message.header.messageId.map { "<\($0.localPart)@\($0.domain)>" })
    }

    func send(to: [String], subject: String, body: String) async throws {
        let smtp = SMTPServer(host: "smtp.mail.me.com", port: 587)
        try await smtp.connect()
        try await smtp.login(username: address, password: password)
        let email = Email(
            sender: EmailAddress(address: address),
            recipients: to.map { EmailAddress(address: $0) },
            subject: subject,
            textBody: body)
        _ = try await smtp.sendEmail(email)
        try? await smtp.disconnect()
    }

    func reply(to message: MailMessage, body: String) async throws {
        try await send(
            to: [message.fromAddress], subject: MailText.replySubject(message.subject), body: body)
    }

    // MARK: Internos

    private func openInbox() async throws -> IMAPServer {
        let imap = IMAPServer(host: "imap.mail.me.com", port: 993)
        try await imap.connect()
        // O iCloud aceita o usuário com ou sem o domínio; usamos o e-mail completo.
        try await imap.login(username: address, password: password)
        try await imap.selectMailbox("INBOX")
        return imap
    }

    private static func mailboxes(_ entries: [AddressListEntry]) -> [EmailAddress] {
        entries.flatMap { entry -> [EmailAddress] in
            switch entry {
            case .mailbox(let address): [address]
            case .group(_, let members): members
            case .invalid: []
            }
        }
    }

    private static func addresses(_ entries: [AddressListEntry]) -> [String] {
        mailboxes(entries).map(\.address)
    }

    private static func name(_ entries: [AddressListEntry]) -> String {
        guard let first = mailboxes(entries).first else { return "desconhecido" }
        if let name = first.name, !name.isEmpty { return name }
        return first.address
    }
}
