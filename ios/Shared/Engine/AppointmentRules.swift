import Foundation

/// Which of today's appointments the bar offers. Pure: the caller passes the time.
enum AppointmentRules {
    /// The latest ended appointment with a known client and no invoice today.
    static func toBill(_ list: [Appointment], now: Date, billed: Set<String>) -> Appointment? {
        list.last { $0.end <= now && !$0.billed && !billed.contains($0.id) && ($0.clientName ?? $0.clientEmail) != nil }
    }

    static func nextUp(_ list: [Appointment], now: Date) -> Appointment? {
        list.first { $0.start > now }
    }
}
