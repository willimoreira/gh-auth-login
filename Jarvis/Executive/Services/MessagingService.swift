import MessageUI
import SwiftUI
import UIKit

/// iMessage/SMS, WhatsApp e ligações. O iOS não permite que apps enviem mensagens sozinhos:
/// o Jarvis prepara tudo e você só toca em "Enviar".
@MainActor
@Observable
final class MessagingService {

    struct Draft: Identifiable {
        let id = UUID()
        let recipients: [String]
        let body: String
    }

    /// Rascunho de iMessage/SMS aguardando a tela de envio.
    var composeDraft: Draft?

    var canSendTexts: Bool { MFMessageComposeViewController.canSendText() }

    func composeText(to phones: [String], body: String) {
        composeDraft = Draft(recipients: phones, body: body)
    }

    /// Abre o WhatsApp na conversa com o texto já escrito.
    func openWhatsApp(phone: String, body: String) -> Bool {
        var digits = phone.filter(\.isNumber)
        // Número brasileiro sem DDI: assume +55.
        if digits.count <= 11, !phone.hasPrefix("+") { digits = "55" + digits }
        var components = URLComponents(string: "https://wa.me/\(digits)")!
        components.queryItems = [URLQueryItem(name: "text", value: body)]
        guard let url = components.url else { return false }
        UIApplication.shared.open(url)
        return true
    }

    func call(phone: String) -> Bool {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)") else { return false }
        UIApplication.shared.open(url)
        return true
    }
}

/// Tela nativa de envio de iMessage/SMS.
struct MessageComposeView: UIViewControllerRepresentable {
    let draft: MessagingService.Draft
    let onFinish: (MessageComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = draft.recipients
        controller.body = draft.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void
        init(onFinish: @escaping (MessageComposeResult) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult
        ) {
            onFinish(result)
        }
    }
}
