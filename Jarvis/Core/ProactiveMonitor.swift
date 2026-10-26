import EventKit
import UIKit
import UserNotifications

/// Iniciativa própria do J.A.R.V.I.S.: avisa de compromissos próximos, bateria fraca e faz
/// o resumo da manhã. Fala quando o app está ativo (inclusive em segundo plano) e agenda
/// notificações para os compromissos, que chegam mesmo com o app fechado.
@MainActor
final class ProactiveMonitor {

    /// Fala algo por iniciativa própria.
    var announce: ((String) -> Void)?
    /// Só fala quando não interrompe nada (em espera ou aguardando o nome).
    var canSpeakNow: (() -> Bool)?

    private let calendar: CalendarService
    private let settings: JarvisSettings
    private var timer: Timer?
    private var queue: [String] = []
    private var announcedEvents: Set<String> = []
    private var batteryWarned = false
    private var lastNotificationSync = Date.distantPast

    init(calendar: CalendarService, settings: JarvisSettings) {
        self.calendar = calendar
        self.settings = settings
    }

    func start() {
        guard timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queue.removeAll()
    }

    private func tick() {
        guard settings.proactive else { return }
        checkUpcomingEvents()
        checkBattery()
        checkMorningBriefing()
        if Date().timeIntervalSince(lastNotificationSync) > 15 * 60 {
            lastNotificationSync = Date()
            Task { await syncEventNotifications() }
        }
        deliver()
    }

    private func deliver() {
        guard !queue.isEmpty, canSpeakNow?() == true else { return }
        announce?(queue.joined(separator: " "))
        queue.removeAll()
    }

    // MARK: Verificações

    private func checkUpcomingEvents() {
        let now = Date()
        guard let events = try? calendar.events(from: now, to: now.addingTimeInterval(15 * 60)) else { return }
        for event in events where !event.isAllDay {
            let id = event.eventIdentifier ?? event.title ?? ""
            let minutes = Int((event.startDate.timeIntervalSince(now) / 60).rounded())
            guard minutes >= 0, minutes <= 10, !announcedEvents.contains(id) else { continue }
            announcedEvents.insert(id)
            queue.append(eventReminder(event, minutes: minutes))
        }
    }

    private func checkBattery() {
        let device = UIDevice.current
        guard device.batteryLevel >= 0 else { return }
        if device.batteryState == .charging || device.batteryState == .full {
            batteryWarned = false
            return
        }
        guard device.batteryLevel < 0.2, !batteryWarned else { return }
        batteryWarned = true
        let percent = Int(device.batteryLevel * 100)
        queue.append(
            settings.language == .portuguese
                ? "\(settings.honorific.capitalized), a bateria está em \(percent) por cento. Sugiro conectar o carregador."
                : "\(settings.honorific.capitalized), battery is at \(percent) percent. I'd suggest plugging in.")
    }

    /// Uma vez por dia, de manhã: resumo da agenda do dia.
    private func checkMorningBriefing() {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        guard (6..<12).contains(hour) else { return }
        let today = Calendar.current.startOfDay(for: now)
        let key = "lastBriefing"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, last >= today { return }
        UserDefaults.standard.set(now, forKey: key)

        let end = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? now
        let events = ((try? calendar.events(from: now, to: end)) ?? []).filter { !$0.isAllDay }
        queue.append(briefing(events))
    }

    // MARK: Notificações (funcionam mesmo com o app fechado)

    private func syncEventNotifications() async {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let events = ((try? calendar.events(from: now, to: now.addingTimeInterval(24 * 3600))) ?? [])
            .filter { !$0.isAllDay }

        let pending = await center.pendingNotificationRequests()
        let old = pending.map(\.identifier).filter { $0.hasPrefix("jarvis.event.") }
        center.removePendingNotificationRequests(withIdentifiers: old)

        for event in events {
            let fireDate = event.startDate.addingTimeInterval(-10 * 60)
            guard fireDate > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "J.A.R.V.I.S."
            content.body = eventReminder(event, minutes: 10)
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let request = UNNotificationRequest(
                identifier: "jarvis.event.\(event.eventIdentifier ?? UUID().uuidString)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }

    // MARK: Textos

    private func eventReminder(_ event: EKEvent, minutes: Int) -> String {
        let title = event.title ?? (settings.language == .portuguese ? "um compromisso" : "an appointment")
        let place = event.location.flatMap { $0.isEmpty ? nil : $0 }
        let who = settings.honorific.capitalized
        switch settings.language {
        case .portuguese:
            let when = minutes <= 1 ? "agora" : "em \(minutes) minutos"
            return "\(who), \(title) começa \(when)" + (place.map { ", em \($0)." } ?? ".")
        case .english:
            let when = minutes <= 1 ? "now" : "in \(minutes) minutes"
            return "\(who), \(title) starts \(when)" + (place.map { ", at \($0)." } ?? ".")
        }
    }

    private func briefing(_ events: [EKEvent]) -> String {
        let formatter = DateFormatter()
        formatter.locale = settings.language.locale
        formatter.timeStyle = .short
        let items = events.prefix(3).map { "\($0.title ?? "") às \(formatter.string(from: $0.startDate))" }
        let who = settings.honorific
        switch settings.language {
        case .portuguese:
            if events.isEmpty {
                return "Bom dia, \(who). Sua agenda de hoje está livre."
            }
            let count = events.count == 1 ? "um compromisso" : "\(events.count) compromissos"
            return "Bom dia, \(who). Hoje o senhor tem \(count): \(items.joined(separator: "; "))."
        case .english:
            if events.isEmpty {
                return "Good morning, \(who). Your calendar is clear today."
            }
            let english = events.prefix(3).map { "\($0.title ?? "") at \(formatter.string(from: $0.startDate))" }
            return "Good morning, \(who). You have \(events.count) appointments today: \(english.joined(separator: "; "))."
        }
    }
}
