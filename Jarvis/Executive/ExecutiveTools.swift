import EventKit
import Foundation
import MLXLMCommon

/// Ação que altera algo fora do app (enviar, remarcar, apagar…) e espera o "confirmar" do usuário.
struct PendingAction {
    let summary: String
    let perform: @MainActor () async throws -> String
}

/// Ferramentas do assistente executivo que o Gemma 4 pode chamar (tool calling).
/// Leituras rodam na hora; ações que enviam, mudam ou apagam ficam pendentes até confirmação.
@MainActor
@Observable
final class ExecutiveTools {

    let mail = MailHub()
    let calendar = CalendarService()
    let contacts = ContactsService()
    let messaging = MessagingService()

    /// Ação aguardando "confirmar".
    private(set) var pending: PendingAction?

    func requestPermissions() async {
        await calendar.requestAccess()
        await contacts.requestAccess()
    }

    func cancelPending() { pending = nil }

    /// Executa a ação pendente e devolve a frase de resultado.
    func confirmPending() async -> String {
        guard let action = pending else { return "Não há nada aguardando confirmação." }
        pending = nil
        do {
            return try await action.perform()
        } catch {
            return "Não consegui concluir: \(error.localizedDescription)"
        }
    }

    // MARK: Definições (JSON Schema enviado ao modelo)

    var specs: [ToolSpec] {
        [
            spec("calendar_list_events", "List calendar events between two dates (inclusive). Use for 'what do I have today/tomorrow/this week'.", [
                .required("start", type: .string, description: "Start, ISO 8601 local time, e.g. 2026-10-27 or 2026-10-27T09:00"),
                .required("end", type: .string, description: "End, ISO 8601 local time, e.g. 2026-10-27T23:59"),
            ]),
            spec("calendar_create_event", "Create a calendar event (asks the user to confirm).", [
                .required("title", type: .string, description: "Event title"),
                .required("start", type: .string, description: "Start, ISO 8601 local time, e.g. 2026-10-28T15:00"),
                .optional("end", type: .string, description: "End, ISO 8601. Defaults to 1 hour after start"),
                .optional("location", type: .string, description: "Location"),
                .optional("notes", type: .string, description: "Notes"),
                .optional("alert_minutes", type: .int, description: "Alert this many minutes before"),
            ]),
            spec("calendar_update_event", "Move/rename an existing event by id from calendar_list_events (asks to confirm).", [
                .required("event_id", type: .string, description: "Event id"),
                .optional("new_start", type: .string, description: "New start, ISO 8601 local time"),
                .optional("new_end", type: .string, description: "New end, ISO 8601 local time"),
                .optional("new_title", type: .string, description: "New title"),
                .optional("new_location", type: .string, description: "New location"),
            ]),
            spec("calendar_delete_event", "Cancel/delete an event by id (asks to confirm).", [
                .required("event_id", type: .string, description: "Event id")
            ]),
            spec("reminders_list", "List pending reminders/tasks.", []),
            spec("reminder_create", "Create a reminder/task, optionally with a due time.", [
                .required("title", type: .string, description: "What to remember"),
                .optional("due", type: .string, description: "When, ISO 8601 local time"),
                .optional("notes", type: .string, description: "Notes"),
            ]),
            spec("reminder_complete", "Mark a reminder as done by id from reminders_list.", [
                .required("reminder_id", type: .string, description: "Reminder id")
            ]),
            spec("contact_lookup", "Find a contact's phone numbers and emails by name.", [
                .required("name", type: .string, description: "Name or part of it")
            ]),
            spec("email_list", "List recent emails from the inbox (all connected accounts unless one is given).", [
                .optional("account", type: .string, description: "gmail, outlook or icloud"),
                .optional("search", type: .string, description: "Text to search (sender, subject, words)"),
                .optional("unread_only", type: .bool, description: "Only unread emails"),
                .optional("max", type: .int, description: "How many, default 5"),
            ]),
            spec("email_read", "Read the full content of an email by id from email_list.", [
                .required("email_id", type: .string, description: "Email id like gmail:abc")
            ]),
            spec("email_send", "Send a new email (asks the user to confirm). 'to' may be an address or a contact name.", [
                .required("to", type: .string, description: "Recipient address or contact name; separate several with commas"),
                .required("subject", type: .string, description: "Subject"),
                .required("body", type: .string, description: "Full email text, written in the user's voice and signed with their name"),
                .optional("account", type: .string, description: "gmail, outlook or icloud"),
            ]),
            spec("email_reply", "Reply to an email by id (asks the user to confirm).", [
                .required("email_id", type: .string, description: "Email id from email_list"),
                .required("body", type: .string, description: "Reply text"),
            ]),
            spec("message_send", "Send a text message via iMessage/SMS or WhatsApp (user confirms, then taps Send).", [
                .required("to", type: .string, description: "Contact name or phone number"),
                .required("text", type: .string, description: "Message text"),
                .optional("app", type: .string, description: "imessage (default) or whatsapp"),
            ]),
            spec("phone_call", "Start a phone call to a contact or number (asks to confirm).", [
                .required("to", type: .string, description: "Contact name or phone number")
            ]),
        ]
    }

    private func spec(_ name: String, _ description: String, _ parameters: [ToolParameter]) -> ToolSpec {
        Tool<EmptyInput, String>(name: name, description: description, parameters: parameters) { _ in "" }
            .schema
    }

    private struct EmptyInput: Codable {}

    // MARK: Execução

    /// Chamado pelo ChatSession quando o modelo pede uma ferramenta.
    func dispatch(_ call: ToolCall) async -> String {
        let args = Args(call.function.arguments)
        do {
            let output = try await run(call.function.name, args)
            return String(output.prefix(2500))
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    private func run(_ name: String, _ args: Args) async throws -> String {
        switch name {
        case "calendar_list_events":
            let start = try args.date("start")
            var end = try args.date("end")
            if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: start)! }
            let events = try calendar.events(from: start, to: end)
            if events.isEmpty { return "No events in this period." }
            return events.map { event in
                var line = "id=\(event.eventIdentifier ?? "?") | \(Format.when(event.startDate, allDay: event.isAllDay))"
                if !event.isAllDay { line += "–\(Format.time(event.endDate))" }
                line += " | \(event.title ?? "(sem título)")"
                if let location = event.location, !location.isEmpty { line += " | local: \(location)" }
                return line
            }.joined(separator: "\n")

        case "calendar_create_event":
            let title = try args.string("title")
            let start = try args.date("start")
            let end = try args.optionalDate("end") ?? start.addingTimeInterval(3600)
            let location = args.optionalString("location")
            let notes = args.optionalString("notes")
            let alert = args.optionalInt("alert_minutes")
            return ask("Criar o evento \"\(title)\" em \(Format.spoken(start))\(location.map { ", em \($0)" } ?? "")") {
                [calendar] in
                try calendar.createEvent(
                    title: title, start: start, end: end, location: location, notes: notes, alertMinutes: alert)
                return "Evento \"\(title)\" criado para \(Format.spoken(start))."
            }

        case "calendar_update_event":
            let event = try calendar.event(id: try args.string("event_id"))
            let newStart = try args.optionalDate("new_start")
            let newEnd = try args.optionalDate("new_end")
            let newTitle = args.optionalString("new_title")
            let newLocation = args.optionalString("new_location")
            var changes: [String] = []
            if let newStart { changes.append("para \(Format.spoken(newStart))") }
            if let newTitle { changes.append("com o título \"\(newTitle)\"") }
            if let newLocation { changes.append("no local \(newLocation)") }
            let title = event.title ?? "evento"
            return ask("Alterar \"\(title)\" \(changes.joined(separator: ", "))") { [calendar] in
                try calendar.update(event, title: newTitle, start: newStart, end: newEnd, location: newLocation)
                return "\"\(title)\" atualizado."
            }

        case "calendar_delete_event":
            let event = try calendar.event(id: try args.string("event_id"))
            let title = event.title ?? "evento"
            return ask("Cancelar \"\(title)\" de \(Format.spoken(event.startDate))") { [calendar] in
                try calendar.delete(event)
                return "\"\(title)\" foi cancelado."
            }

        case "reminders_list":
            let reminders = try await calendar.reminders()
            if reminders.isEmpty { return "No pending reminders." }
            return reminders.prefix(15).map { reminder in
                var line = "id=\(reminder.calendarItemIdentifier) | \(reminder.title ?? "")"
                if let components = reminder.dueDateComponents,
                    let due = Calendar.current.date(from: components)
                {
                    line += " | até \(Format.when(due, allDay: false))"
                }
                return line
            }.joined(separator: "\n")

        case "reminder_create":
            let title = try args.string("title")
            let due = try args.optionalDate("due")
            try calendar.createReminder(title: title, due: due, notes: args.optionalString("notes"))
            return "Reminder created: \(title)\(due.map { " for \(Format.spoken($0))" } ?? "")."

        case "reminder_complete":
            let title = try calendar.completeReminder(id: try args.string("reminder_id"))
            return "Reminder done: \(title)."

        case "contact_lookup":
            let matches = try contacts.find(try args.string("name"))
            if matches.isEmpty { return "No contact found." }
            return matches.map {
                "\($0.name) | tel: \($0.phones.joined(separator: ", ")) | email: \($0.emails.joined(separator: ", "))"
            }.joined(separator: "\n")

        case "email_list":
            let provider = try args.provider("account")
            let items = try await mail.list(
                provider: provider, query: args.optionalString("search"),
                unreadOnly: args.optionalBool("unread_only") ?? false,
                max: min(max(args.optionalInt("max") ?? 5, 1), 10))
            if items.isEmpty { return "No emails found." }
            return items.map { provider, item in
                var line = "id=\(item.id) | \(provider.spokenName) | de: \(item.from) | \(item.subject)"
                if let date = item.date { line += " | \(Format.when(date, allDay: false))" }
                if item.unread { line += " | NÃO LIDO" }
                if !item.preview.isEmpty { line += " | \(item.preview.prefix(120))" }
                return line
            }.joined(separator: "\n")

        case "email_read":
            let message = try await mail.read(globalID: try args.string("email_id"))
            return """
                id=\(message.id)
                de: \(message.from) <\(message.fromAddress)>
                assunto: \(message.subject)
                data: \(message.date.map { Format.when($0, allDay: false) } ?? "?")

                \(message.body.prefix(1800))
                """

        case "email_send":
            let to = try resolveEmails(try args.string("to"))
            let subject = try args.string("subject")
            let body = try args.string("body")
            let provider = try args.provider("account")
            let from = (provider ?? mail.connectedProviders.first)?.spokenName ?? "e-mail"
            return ask("Enviar pelo \(from) para \(to.joined(separator: ", ")), assunto \"\(subject)\": \(body)") {
                [mail] in
                let used = try await mail.send(provider: provider, to: to, subject: subject, body: body)
                return "E-mail enviado pelo \(used.spokenName)."
            }

        case "email_reply":
            let id = try args.string("email_id")
            let body = try args.string("body")
            let original = try await mail.read(globalID: id)
            return ask("Responder a \(original.from) sobre \"\(original.subject)\": \(body)") { [mail] in
                try await mail.reply(globalID: id, body: body)
                return "Resposta enviada para \(original.from)."
            }

        case "message_send":
            let target = try resolvePhone(try args.string("to"))
            let text = try args.string("text")
            let whatsapp = (args.optionalString("app") ?? "").lowercased().contains("whats")
            let app = whatsapp ? "WhatsApp" : "iMessage"
            return ask("Mandar por \(app) para \(target.name): \(text)") { [messaging] in
                if whatsapp {
                    _ = messaging.openWhatsApp(phone: target.phone, body: text)
                    return "Abri o WhatsApp com a mensagem para \(target.name). É só tocar em enviar."
                }
                guard messaging.canSendTexts else { return "Este aparelho não pode enviar mensagens." }
                messaging.composeText(to: [target.phone], body: text)
                return "Mensagem pronta para \(target.name). Toque em enviar."
            }

        case "phone_call":
            let target = try resolvePhone(try args.string("to"))
            return ask("Ligar para \(target.name)") { [messaging] in
                _ = messaging.call(phone: target.phone)
                return "Ligando para \(target.name)."
            }

        default:
            return "ERROR: unknown tool \(name)"
        }
    }

    /// Registra a ação como pendente e instrui o modelo a pedir confirmação.
    private func ask(_ summary: String, perform: @escaping @MainActor () async throws -> String) -> String {
        pending = PendingAction(summary: summary, perform: perform)
        return """
            CONFIRMATION_REQUIRED. Nothing was done yet. Briefly tell the user exactly what will happen \
            (\(summary)) and ask them to say "confirmar" or "cancelar". Do not say it is done.
            """
    }

    private func resolveEmails(_ raw: String) throws -> [String] {
        try raw.split(separator: ",").map { part in
            let item = part.trimmingCharacters(in: .whitespaces)
            if item.contains("@") { return item }
            guard let email = try contacts.find(item).first?.emails.first else {
                throw ServiceError.notFound("No email address found for \(item) in contacts.")
            }
            return email
        }
    }

    private func resolvePhone(_ raw: String) throws -> (name: String, phone: String) {
        let digits = raw.filter(\.isNumber)
        if digits.count >= 8 { return (raw, raw) }
        guard let match = try contacts.find(raw).first, let phone = match.phones.first else {
            throw ServiceError.notFound("No phone number found for \(raw) in contacts.")
        }
        return (match.name, phone)
    }
}

/// Leitura tolerante dos argumentos que o modelo envia.
struct Args {
    private let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    func optionalString(_ key: String) -> String? {
        switch values[key] {
        case .string(let s): s.isEmpty ? nil : s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): String(b)
        default: nil
        }
    }

    func string(_ key: String) throws -> String {
        guard let value = optionalString(key) else { throw ServiceError.invalid("Missing argument '\(key)'.") }
        return value
    }

    func optionalInt(_ key: String) -> Int? {
        switch values[key] {
        case .int(let i): i
        case .double(let d): Int(d)
        case .string(let s): Int(s)
        default: nil
        }
    }

    func optionalBool(_ key: String) -> Bool? {
        switch values[key] {
        case .bool(let b): b
        case .string(let s): ["true", "sim", "yes", "1"].contains(s.lowercased())
        case .int(let i): i != 0
        default: nil
        }
    }

    func optionalDate(_ key: String) throws -> Date? {
        guard let raw = optionalString(key) else { return nil }
        guard let date = Format.parse(raw) else {
            throw ServiceError.invalid("Invalid date '\(raw)' for \(key). Use ISO 8601 like 2026-10-27T15:00.")
        }
        return date
    }

    func date(_ key: String) throws -> Date {
        guard let date = try optionalDate(key) else { throw ServiceError.invalid("Missing argument '\(key)'.") }
        return date
    }

    func provider(_ key: String) throws -> MailProvider? {
        guard let raw = optionalString(key)?.lowercased() else { return nil }
        if raw.contains("gmail") || raw.contains("google") { return .gmail }
        if raw.contains("outlook") || raw.contains("hotmail") || raw.contains("msn") || raw.contains("live") {
            return .outlook
        }
        if raw.contains("icloud") || raw.contains("apple") { return .icloud }
        return nil
    }
}

/// Datas: leitura de ISO 8601 local e formatos para o modelo e para a fala.
enum Format {
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = pattern
            if let date = formatter.date(from: String(text.prefix(pattern.replacingOccurrences(of: "'", with: "").count))) {
                return date
            }
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// "2026-10-27T15:00 (ter)" — preciso para o modelo raciocinar sobre datas.
    static func when(_ date: Date, allDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = allDay ? "yyyy-MM-dd '(dia todo,' EEE')'" : "yyyy-MM-dd'T'HH:mm '('EEE')'"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "terça, 27 de outubro às 15:00" — para falar ao usuário.
    static func spoken(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE, d 'de' MMMM 'às' HH:mm"
        return formatter.string(from: date)
    }
}
