import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Configuração OAuth 2.0 (PKCE, cliente público, sem segredo no app) de um provedor.
struct OAuthProvider: Sendable {
    let id: String
    let authorizeURL: URL
    let tokenURL: URL
    let scopes: [String]
    let clientID: String
    let redirectURI: String
    var extraAuthParams: [String: String] = [:]

    /// Esquema do redirect (parte antes de ":"), usado pelo ASWebAuthenticationSession.
    var callbackScheme: String {
        String(redirectURI.prefix { $0 != ":" })
    }

    /// Gmail: cliente OAuth do tipo **iOS** criado no Google Cloud com o bundle ID do app.
    static func google(clientID: String) -> OAuthProvider {
        // O redirect de clientes iOS do Google é o client ID invertido.
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        return OAuthProvider(
            id: "google",
            authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            scopes: ["https://www.googleapis.com/auth/gmail.modify", "email"],
            clientID: clientID,
            redirectURI: "\(reversed):/oauth2redirect",
            extraAuthParams: ["access_type": "offline", "prompt": "consent"]
        )
    }

    /// Outlook/Hotmail/MSN: app registrado no Microsoft Entra (plataforma iOS) com o bundle ID.
    static func microsoft(clientID: String, bundleID: String) -> OAuthProvider {
        OAuthProvider(
            id: "microsoft",
            authorizeURL: URL(
                string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: ["offline_access", "User.Read", "Mail.ReadWrite", "Mail.Send"],
            clientID: clientID,
            redirectURI: "msauth.\(bundleID)://auth",
            extraAuthParams: ["prompt": "select_account"]
        )
    }
}

struct OAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    var isExpired: Bool { Date() > expiresAt.addingTimeInterval(-60) }
}

enum OAuthError: LocalizedError {
    case cancelled
    case invalidCallback
    case tokenExchange(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .cancelled: "Login cancelado."
        case .invalidCallback: "Resposta de login inválida."
        case .tokenExchange(let detail): "Falha ao obter o token: \(detail)"
        case .notConnected: "Conta não conectada."
        }
    }
}

/// Faz o login no navegador seguro do sistema e mantém os tokens renovados no Keychain.
@MainActor
final class OAuthClient: NSObject, ASWebAuthenticationPresentationContextProviding {

    let provider: OAuthProvider
    /// A sessão precisa ficar retida enquanto a tela de login está aberta.
    private var webSession: ASWebAuthenticationSession?
    private var keychainKey: String { "oauth.\(provider.id)" }

    init(provider: OAuthProvider) {
        self.provider = provider
    }

    var storedTokens: OAuthTokens? {
        Keychain.codable(OAuthTokens.self, for: keychainKey)
    }

    func signOut() {
        Keychain.delete(keychainKey)
    }

    /// Abre a tela de login do provedor e guarda os tokens.
    func signIn() async throws {
        let verifier = Self.randomString(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(24)

        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: provider.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        items += provider.extraAuthParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items

        let callback = try await authenticate(url: components.url!)
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == state,
            let code = query.first(where: { $0.name == "code" })?.value
        else { throw OAuthError.invalidCallback }

        let tokens = try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": provider.redirectURI,
            "client_id": provider.clientID,
            "code_verifier": verifier,
        ])
        Keychain.setCodable(tokens, for: keychainKey)
    }

    /// Token de acesso válido, renovando com o refresh token quando expira.
    func accessToken() async throws -> String {
        guard var tokens = storedTokens else { throw OAuthError.notConnected }
        if !tokens.isExpired { return tokens.accessToken }
        guard let refresh = tokens.refreshToken else { throw OAuthError.notConnected }
        let renewed = try await requestTokens([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": provider.clientID,
        ])
        tokens.accessToken = renewed.accessToken
        tokens.expiresAt = renewed.expiresAt
        if let newRefresh = renewed.refreshToken { tokens.refreshToken = newRefresh }
        Keychain.setCodable(tokens, for: keychainKey)
        return tokens.accessToken
    }

    private func requestTokens(_ form: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: provider.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let access = json["access_token"] as? String
        else {
            let detail =
                json["error_description"] as? String ?? json["error"] as? String
                ?? String(decoding: data, as: UTF8.self)
            throw OAuthError.tokenExchange(detail)
        }
        let expiresIn = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        return OAuthTokens(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: Date().addingTimeInterval(expiresIn))
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: provider.callbackScheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                    error.code == .canceledLogin
                {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
        -> ASPresentationAnchor
    {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }

    // MARK: Utilidades

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return form.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)"
        }.joined(separator: "&")
    }

    static func randomString(_ length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
