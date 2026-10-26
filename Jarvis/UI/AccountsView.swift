import SwiftUI

/// Conexão das contas de e-mail (Gmail, Outlook, iCloud).
struct AccountsView: View {
    @Environment(JarvisAssistant.self) private var jarvis
    @State private var icloudAddress = ""
    @State private var icloudPassword = ""

    private var hub: MailHub { jarvis.tools.mail }

    var body: some View {
        @Bindable var hub = jarvis.tools.mail

        Form {
            Section {
                statusRow(.gmail)
                if !(hub.status[.gmail]?.connected ?? false) {
                    TextField("Client ID (iOS) do Google", text: $hub.googleClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button("Conectar Gmail") { Task { await hub.connectGmail() } }
                        .disabled(hub.googleClientID.isEmpty || isBusy(.gmail))
                }
            } header: {
                Text("Gmail")
            } footer: {
                Text(
                    "Uma vez só: em console.cloud.google.com crie um projeto, ative a Gmail API, configure a Tela de consentimento (adicione seu e-mail como usuário de teste) e crie uma credencial OAuth do tipo iOS com o bundle ID \(Bundle.main.bundleIdentifier ?? "com.willimoreira.jarvis"). Cole o Client ID aqui."
                )
            }

            Section {
                statusRow(.outlook)
                if !(hub.status[.outlook]?.connected ?? false) {
                    TextField("Application (client) ID da Microsoft", text: $hub.microsoftClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button("Conectar Outlook / MSN") { Task { await hub.connectOutlook() } }
                        .disabled(hub.microsoftClientID.isEmpty || isBusy(.outlook))
                }
            } header: {
                Text("Outlook / Hotmail / MSN")
            } footer: {
                Text(
                    "Uma vez só: em entra.microsoft.com › Registros de aplicativo › Novo registro, escolha \"Contas pessoais e organizacionais\", adicione a plataforma iOS com o bundle ID \(Bundle.main.bundleIdentifier ?? "com.willimoreira.jarvis") e copie o Application (client) ID."
                )
            }

            Section {
                statusRow(.icloud)
                if !(hub.status[.icloud]?.connected ?? false) {
                    TextField("seu@icloud.com", text: $icloudAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Senha de app (xxxx-xxxx-xxxx-xxxx)", text: $icloudPassword)
                    Button("Conectar iCloud Mail") {
                        Task { await hub.connectICloud(address: icloudAddress, appPassword: icloudPassword) }
                    }
                    .disabled(icloudAddress.isEmpty || icloudPassword.isEmpty || isBusy(.icloud))
                }
            } header: {
                Text("iCloud Mail")
            } footer: {
                Text(
                    "Gere uma senha de app em account.apple.com › Login e Segurança › Senhas de app. Não use a senha do seu Apple ID."
                )
            }

            Section {
                Label("Calendário, Lembretes e Contatos usam as contas já configuradas no iPhone (Ajustes › Calendário › Contas), incluindo Google e Outlook.", systemImage: "calendar")
                Label("iMessage, SMS e WhatsApp: o Jarvis escreve e você toca em Enviar — o iOS não permite envio automático.", systemImage: "message")
            } header: {
                Text("Outros serviços")
            }
        }
        .navigationTitle("Contas")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func statusRow(_ provider: MailProvider) -> some View {
        let status = hub.status[provider] ?? .init()
        HStack {
            if status.busy {
                ProgressView()
                Text("Conectando…")
            } else if status.connected {
                Label(status.address, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Desconectar", role: .destructive) { hub.disconnect(provider) }
                    .buttonStyle(.borderless)
            } else {
                Label("Não conectado", systemImage: "circle").foregroundStyle(.secondary)
            }
        }
        if let error = status.error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func isBusy(_ provider: MailProvider) -> Bool {
        hub.status[provider]?.busy ?? false
    }
}

/// Cartão do HUD com a ação aguardando confirmação.
struct PendingActionCard: View {
    let summary: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HUDPanel(title: "Autorização necessária") {
            Text(summary)
                .font(HUD.mono(12))
                .foregroundStyle(HUD.ice)
                .lineLimit(5)
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("CANCELAR")
                        .font(HUD.mono(12, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .overlay(CornerBrackets(length: 6).stroke(HUD.red, lineWidth: 1))
                        .foregroundStyle(HUD.red)
                }
                Button(action: onConfirm) {
                    Text("CONFIRMAR")
                        .font(HUD.mono(12, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(HUD.cyan.opacity(0.15))
                        .overlay(CornerBrackets(length: 6).stroke(HUD.cyan, lineWidth: 1))
                        .foregroundStyle(HUD.cyan)
                        .glow(HUD.cyan, radius: 4)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
