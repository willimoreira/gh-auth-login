import EventKit
import Foundation

/// Calendário e Lembretes do iPhone (inclui contas iCloud, Google e Outlook configuradas
/// em Ajustes › Calendário › Contas).
@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private var eventsGranted = false
    private var remindersGranted = false

    func requestAccess() async {
        eventsGranted = (try? await store.requestFullAccessToEvents()) ?? false
        remindersGranted = (try? await store.requestFullAccessToReminders()) ?? false
    }

    // MARK: Eventos

    func events(from start: Date, to end: Date) throws -> [EKEvent] {
        try ensure(eventsGranted, "calendário")
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func event(id: String) throws -> EKEvent {
        try ensure(eventsGranted, "calendário")
        guard let event = store.event(withIdentifier: id) else {
            throw ServiceError.notFound("Evento não encontrado. Liste a agenda de novo.")
        }
        return event
    }

    @discardableResult
    func createEvent(
        title: String, start: Date, end: Date, location: String?, notes: String?, alertMinutes: Int?
    ) throws -> EKEvent {
        try ensure(eventsGranted, "calendário")
        let event = EKEvent(eventStore: store)
        event.calendar = store.defaultCalendarForNewEvents
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        if let alertMinutes { event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alertMinutes * 60))) }
        try store.save(event, span: .thisEvent)
        return event
    }

    func update(_ event: EKEvent, title: String?, start: Date?, end: Date?, location: String?) throws {
        let duration = event.endDate.timeIntervalSince(event.startDate)
        if let title { event.title = title }
        if let start {
            event.startDate = start
            event.endDate = end ?? start.addingTimeInterval(duration)
        } else if let end {
            event.endDate = end
        }
        if let location { event.location = location }
        try store.save(event, span: .thisEvent)
    }

    func delete(_ event: EKEvent) throws {
        try store.remove(event, span: .thisEvent)
    }

    // MARK: Lembretes

    func reminders(includeCompleted: Bool = false) async throws -> [EKReminder] {
        try ensure(remindersGranted, "lembretes")
        let predicate =
            includeCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        return fetched
    }

    @discardableResult
    func createReminder(title: String, due: Date?, notes: String?) throws -> EKReminder {
        try ensure(remindersGranted, "lembretes")
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = store.defaultCalendarForNewReminders()
        reminder.title = title
        reminder.notes = notes
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return reminder
    }

    func completeReminder(id: String) throws -> String {
        try ensure(remindersGranted, "lembretes")
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ServiceError.notFound("Lembrete não encontrado.")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return reminder.title ?? ""
    }

    private func ensure(_ granted: Bool, _ what: String) throws {
        guard granted else {
            throw ServiceError.permission(
                "Sem permissão para o \(what). Libere em Ajustes › Privacidade e Segurança.")
        }
    }
}

enum ServiceError: LocalizedError {
    case permission(String)
    case notFound(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .permission(let m), .notFound(let m), .invalid(let m): m
        }
    }
}
