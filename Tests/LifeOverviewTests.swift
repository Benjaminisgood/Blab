import Foundation

@main
struct LifeOverviewTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-09-08T12:00:00Z")
        let ongoing = entry("跨日旅行", "2026-09-07T20:00:00Z", "2026-09-09T08:00:00Z")
        let midnightEnd = entry("昨天结束", "2026-09-07T20:00:00Z", "2026-09-08T00:00:00Z")
        let morning = entry("早间运动", "2026-09-08T08:00:00Z", nil)
        let afternoon = entry("下午见面", "2026-09-08T15:00:00Z", "2026-09-08T16:00:00Z")
        let deadline = entry("当天截止", nil, "2026-09-08T18:00:00Z")
        let allDay = entry("全天出行", "2026-09-08T00:00:00Z", "2026-09-09T00:00:00Z")
        let tomorrow = entry("明天安排", "2026-09-09T00:00:00Z", nil)
        let undated = entry("阅读计划", nil, nil)
        let overview = LifeOverview(
            entries: [morning, tomorrow, midnightEnd, undated, afternoon, ongoing, deadline, allDay],
            now: now,
            calendar: calendar
        )

        require(Set(overview.today.map(\.id)) == Set([ongoing, morning, afternoon, deadline, allDay].map(\.id)), "today includes overlapping intervals and deadlines only")
        require(overview.today.first?.id == ongoing.id, "ongoing entries precede upcoming and elapsed times")
        require(overview.today.last?.id == morning.id, "elapsed entries follow remaining plans")
        require(overview.upcoming.map(\.id) == [tomorrow.id], "tomorrow midnight begins the future agenda")
        require(overview.unscheduled.map(\.id) == [undated.id], "end-only deadlines are scheduled")
        require(ongoing.isOngoing(at: now) && !ongoing.isElapsed(at: now), "an interval that started yesterday remains active until its end")
        require(!midnightEnd.isOngoing(at: date("2026-09-08T00:00:00Z")), "event stops being ongoing at its exact end")
        require(!deadline.isOngoing(at: now), "a deadline without a start is not an ongoing interval")
        require(morning.isElapsed(at: now), "a passed time is detected without claiming completion")
        let nextDay = LifeOverview(entries: [allDay], now: date("2026-09-09T12:00:00Z"), calendar: calendar)
        require(nextDay.today.isEmpty, "an all-day interval does not spill into its exclusive end date")

        // US daylight saving starts March 8, 2026: this local day has 23 hours.
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let lateLocalDay = entry("变更时区后的晚间", "2026-03-09T06:30:00Z", nil)
        let nextLocalDay = entry("次日凌晨", "2026-03-09T07:00:00Z", nil)
        let daylightSaving = LifeOverview(entries: [lateLocalDay, nextLocalDay], now: date("2026-03-08T16:00:00Z"), calendar: calendar)
        require(daylightSaving.today.map(\.id) == [lateLocalDay.id], "calendar day boundaries respect daylight saving")
        require(daylightSaving.upcoming.map(\.id) == [nextLocalDay.id], "the next day starts at local midnight")
        print("LifeOverview: 12 checks passed")
    }

    private static func entry(_ title: String, _ start: String?, _ end: String?) -> LifeScheduleEntry {
        LifeScheduleEntry(id: UUID(), title: title, start: start.map(date), end: end.map(date), location: "")
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
