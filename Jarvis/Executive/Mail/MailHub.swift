import Foundation

/// Central de contas de e-mail: conecta, guarda e consulta Gmail, Outlook e iCloud.
@MainActor
@Observable
final class MailHub {

    struct Status: Equatable {
        var connected = false
        var address = ""
        var busy = false
        var error: String?
    }

    private(set) var status: [MailProvider: Status] = [:]

    /// Client IDs dos apps OAuth que você cria (ficam só neste iPhone).
    var googleClientID: String {
        didSet { UserDefaults.standard.set(googleClientID, forKey: "mail.googleClientID") }
    }
    var microsoftClientID: String {
        didSet { UserDefaults.standard.set(microsoftClientID, forKey: "mail.microsoftClientID") }
    }

    private var accounts: [MailProvider: MailAccount] = [:]
    private var oauthClients: [MailProvider: OAuthClient] = [:]
    private let bundleID = Bundle.main.bundleIdentifier ?? "com.willimoreira.jarvis"

    init() {
        googleClientID = UserDefaults.standard.string(forKey: "mail.googleClientID") ?? ""
        microsoftClientID = UserDefaults.standard.string(forKey: "mail.microsoftClientID") ?? ""
        restore()
    }

    var connectedProviders: [MailProvider] {
        MailProvider.allCases.filter { accounts[$0] != nil }
    }

    func account(_ provider: MailProvider) -> MailAccount? { accounts[provider] }

    // MARK: Conectar / desconectar

    func connectGmail() async {
        await connectOAuth(.gmail) { [googleClientID] in
            .google(clientID: googleClientID.trimmingCharacters(in: .whitespaces))
        } profile: { try await GmailAccount.profileAddress(oauth: $0) }
    }

    func connectOutlook() async {
        await connectOAuth(.outlook) { [microsoftClientID, bundleID] in
            .microsoft(clientID: microsoftClientID.trimmingCharacters(in: .whitespaces), bundleID: bundleID)
        } profile: { try await OutlookAccount.profileAddress(oauth: $0) }
    }

    func connectICloud(address: String, appPassword: String) async {
        let address = address.trimmingCharacters(in: .whitespaces).lowercased()
        let password = appPassword.replacingOccurrences(of: " ", with: "")
        status[.icloud] = Status(busy: true)
        let account = ICloudMailAccount(address: address, appPassword: password)
        do {
            try await account.verify()
            Keychain.setCodable(["address": address, "password": password], for: "mail.icloud")
            accounts[.icloud] = account
            status[.icloud] = Status(connected: true, address: address)
        } catch {
            status[.icloud] = Status(error: "Não consegui entrar: \(error.localizedDescription)")
        }
    }

    func disconnect(_ provider: MailProvider) {
        accounts[provider] = nil
        oauthClients[provider]?.signOut()
        oauthClients[provider] = nil
        Keychain.delete("mail.\(provider.rawValue)")
        status[provider] = Status()
    }

    private func connectOAuth(
        _ provider: MailProvider,
        config: () -> OAuthProvider,
        profile: (OAuthClient) async throws -> String
    ) async {
        let oauthProvider = config()
        guard !oauthProvider.clientID.isEmpty else {
            status[provider] = Status(error: "Cole o Client ID antes de conectar.")
            return
        }
        status[provider] = Status(busy: true)
        let client = OAuthClient(provider: oauthProvider)
        do {
            try await client.signIn()
            let address = try await profile(client)
            Keychain.setCodable(["address": address], for: "mail.\(provider.rawValue)")
            oauthClients[provider] = client
            accounts[provider] = makeAccount(provider, client: client, address: address)
            status[provider] = Status(connected: true, address: address)
        } catch {
            client.signOut()
            status[provider] = Status(error: error.localizedDescription)
        }
    }

    private func makeAccount(_ provider: MailProvider, client: OAuthClient, address: String) -> MailAccount {
        switch provider {
        case .gmail: GmailAccount(oauth: client, address: address)
        case .outlook: OutlookAccount(oauth: client, address: address)
        case .icloud: fatalError("iCloud não usa OAuth")
        }
    }

    /// Recarrega as contas salvas no Keychain ao abrir o app.
    private func restore() {
        for provider in MailProvider.allCases {
            status[provider] = Status()
        }
        if let saved = Keychain.codable([String: String].self, for: "mail.icloud"),
            let address = saved["address"], let password = saved["password"]
        {
            accounts[.icloud] = ICloudMailAccount(address: address, appPassword: password)
            status[.icloud] = Status(connected: true, address: address)
        }
        let oauthConfigs: [(MailProvider, OAuthProvider?)] = [
            (.gmail, googleClientID.isEmpty ? nil : .google(clientID: googleClientID)),
            (.outlook, microsoftClientID.isEmpty ? nil : .microsoft(clientID: microsoftClientID, bundleID: bundleID)),
        ]
        for (provider, config) in oauthConfigs {
            guard let config,
                let saved = Keychain.codable([String: String].self, for: "mail.\(provider.rawValue)"),
                let address = saved["address"]
            else { continue }
            let client = OAuthClient(provider: config)
            guard client.storedTokens != nil else { continue }
            oauthClients[provider] = client
            accounts[provider] = makeAccount(provider, client: client, address: address)
            status[provider] = Status(connected: true, address: address)
        }
    }

    // MARK: Operações usadas pelas ferramentas do Jarvis

    /// Lista e-mails de uma conta ou de todas.
    func list(provider: MailProvider?, query: String?, unreadOnly: Bool, max: Int) async throws
        -> [(MailProvider, MailSummary)]
    {
        let targets = provider.map { [$0] } ?? connectedProviders
        guard !targets.isEmpty else { throw MailError.noAccount }
        var all: [(MailProvider, MailSummary)] = []
        var errors: [String] = []
        for target in targets {
            guard let account = accounts[target] else { continue }
            do {
                let items = try await account.list(query: query, unreadOnly: unreadOnly, max: max)
                all += items.map { (target, $0) }
            } catch {
                errors.append("\(target.spokenName): \(error.localizedDescription)")
            }
        }
        if all.isEmpty, let first = errors.first { throw MailError.invalid(first) }
        return all.sorted { ($0.1.date ?? .distantPast) > ($1.1.date ?? .distantPast) }
            .prefix(max).map { $0 }
    }

    func read(globalID: String) async throws -> MailMessage {
        let (account, localID) = try resolve(globalID)
        return try await account.read(id: localID)
    }

    func send(provider: MailProvider?, to: [String], subject: String, body: String) async throws
        -> MailProvider
    {
        guard let target = provider ?? connectedProviders.first, let account = accounts[target] else {
            throw MailError.noAccount
        }
        try await account.send(to: to, subject: subject, body: body)
        return target
    }

    func reply(globalID: String, body: String) async throws {
        let (account, localID) = try resolve(globalID)
        let message = try await account.read(id: localID)
        try await account.reply(to: message, body: body)
    }

    private func resolve(_ globalID: String) throws -> (MailAccount, String) {
        let parts = globalID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = MailProvider(rawValue: parts[0]),
            let account = accounts[provider]
        else { throw MailError.invalid("ID de e-mail inválido: \(globalID). Liste os e-mails de novo.") }
        return (account, parts[1])
    }
}
