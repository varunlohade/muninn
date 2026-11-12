import EventKit
import SwiftUI

/// Reads today's events from the phone calendar (Apple Calendar, with any Google calendars synced to it).
/// Events stay on the device. Only a small snapshot goes to the App Group, for the keyboard.
@MainActor
final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()

    @Published var status = EKEventStore.authorizationStatus(for: .event)
    /// The keyboard adds reminders from typed text ("call supplier at 5"). The app asks; the keyboard cannot.
    @Published var remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Published var today: [Appointment] = []

    private let store = EKEventStore()
    private var clients: [Client] = []
    private var payments: [Payment] = []
    private var changes: Any?

    var connected: Bool { status == .fullAccess }
    /// Either permission has never been asked, so the Connect card still shows.
    var neverAsked: Bool { status == .notDetermined || remindersStatus == .notDetermined }

    init() {
        changes = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Log out: the matched clients and today's list belong to the last user.
    func reset() {
        clients = []
        payments = []
        today = []
    }

    func connect() async {
        if status == .notDetermined { _ = try? await store.requestFullAccessToEvents() }
        if remindersStatus == .notDetermined { _ = try? await store.requestFullAccessToReminders() }
        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        refresh()
    }

    func refresh(clients: [Client], payments: [Payment]) {
        self.clients = clients
        self.payments = payments
        SharedStore.unpaidCount = WhoPaid.count(WhoPaid.clients(payments))
        refresh()
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard connected else { today = []; SharedStore.appointments = []; return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-calendarDemo") { seedDemo() }
        #endif
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: start.addingTimeInterval(86_400), calendars: nil))
        let billed = Set(payments.filter { parseDate($0.created_at).map(cal.isDateInToday) ?? false }.compactMap(\.client_name))
        // Before the first client list arrives (launch, or offline), keep the matches from the last snapshot.
        let last = clients.isEmpty ? Dictionary(SharedStore.appointments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        today = events.filter { !$0.isAllDay && cal.isDateInToday($0.startDate) }.sorted { $0.startDate < $1.startDate }.map { e in
            // Read the URL by key: EventKit can return nil for it, and the Swift property is not optional.
            let people = (e.attendees ?? []).map { ($0.name, (($0.value(forKey: "URL") as? URL)?.absoluteString ?? "").replacingOccurrences(of: "mailto:", with: "")) }
            let client = Self.match(title: e.title ?? "", attendees: people, clients: clients)
            let fresh = Appointment(start: e.startDate, end: e.endDate, title: e.title ?? "Appointment", clientName: client?.name, clientEmail: client?.email,
                                    billed: client.map { billed.contains($0.displayName) } ?? false)
            return last[fresh.id] ?? fresh
        }
        SharedStore.appointments = today
    }

    /// A client matches by email, by full name (the longest wins, so "Sam Okafor" beats "Sam"),
    /// or by a first name that only one client has.
    static func match(title: String, attendees: [(name: String?, email: String)], clients: [Client]) -> Client? {
        let mails = Set(attendees.map { $0.email.lowercased() } + title.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        if let c = clients.first(where: { c in c.email.map { mails.contains($0.lowercased()) } ?? false }) { return c }
        let words = ([title] + attendees.compactMap(\.name)).joined(separator: " ").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let text = " " + words.joined(separator: " ") + " "
        let spaced: (String) -> String = { " " + $0.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " " }
        let full = clients.filter { c in c.name.map { text.contains(spaced($0)) } ?? false }
        if let c = full.max(by: { ($0.name?.count ?? 0) < ($1.name?.count ?? 0) }) { return c }
        let first: (Client) -> String? = { $0.name?.split(separator: " ").first.map { $0.lowercased() } }
        let hits = clients.filter { c in first(c).map(words.contains) ?? false }
        return hits.count == 1 ? hits[0] : nil
    }

    #if DEBUG
    /// "-calendarDemo": four events for today, once. Two have ended, one is next, one has no client.
    private func seedDemo() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let marker = "muninn-demo"
        let existing = store.events(matching: store.predicateForEvents(withStart: day, end: day.addingTimeInterval(86_400), calendars: nil))
        guard !existing.contains(where: { $0.notes == marker }), let target = store.defaultCalendarForNewEvents else { return }
        let now = Date()
        let lastStart = day.addingTimeInterval(86_400 - 1800)
        for (title, offset) in [("Haircut - Sam Okafor", -7200.0), ("Color - Ava Chen", -3600), ("Blowout - Noor Haddad", 3600), ("Supplier call", 9000)] {
            let e = EKEvent(eventStore: store)
            e.title = title
            e.startDate = min(max(now.addingTimeInterval(offset), day), lastStart)
            e.endDate = e.startDate.addingTimeInterval(1800)
            e.notes = marker
            e.calendar = target
            try? store.save(e, span: .thisEvent)
        }
    }
    #endif
}
