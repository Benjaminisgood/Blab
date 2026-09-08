import Foundation

/// A read-only agenda snapshot. Membership and visibility are resolved by the caller.
struct LifeScheduleEntry: Identifiable {
    let id: UUID
    let title: String
    let start: Date?
    let end: Date?
    let location: String

    var scheduledDate: Date? { start ?? end }

    func isOngoing(at now: Date) -> Bool {
        guard let start, let end, end > start else { return false }
        return start <= now && now < end
    }

    func isElapsed(at now: Date) -> Bool {
        guard let date = end ?? start else { return false }
        return date <= now
    }

    func overlaps(_ day: DateInterval) -> Bool {
        if let start, let end, end > start {
            // A midnight end belongs to the previous day. Calendar intervals also
            // handle 23- and 25-hour days correctly when daylight saving changes.
            return start < day.end && end > day.start
        }
        guard let date = scheduledDate else { return false }
        return date >= day.start && date < day.end
    }
}

struct LifeOverview {
    let today: [LifeScheduleEntry]
    let upcoming: [LifeScheduleEntry]
    let unscheduled: [LifeScheduleEntry]

    init(entries: [LifeScheduleEntry], now: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let day = DateInterval(start: start, end: end)

        func chronological(_ lhs: LifeScheduleEntry, _ rhs: LifeScheduleEntry) -> Bool {
            let left = lhs.scheduledDate ?? .distantFuture
            let right = rhs.scheduledDate ?? .distantFuture
            if left != right { return left < right }
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        // Surface ongoing and still-to-come entries before times that have passed.
        // A passed time does not imply that the user completed the event.
        today = entries.filter { $0.overlaps(day) }.sorted { lhs, rhs in
            func priority(_ entry: LifeScheduleEntry) -> Int {
                if entry.isOngoing(at: now) { return 0 }
                return entry.isElapsed(at: now) ? 2 : 1
            }
            let left = priority(lhs), right = priority(rhs)
            return left == right ? chronological(lhs, rhs) : left < right
        }
        upcoming = entries.filter { entry in
            guard let date = entry.scheduledDate else { return false }
            return date >= end
        }.sorted(by: chronological)
        unscheduled = entries.filter { $0.scheduledDate == nil }.sorted(by: chronological)
    }
}
