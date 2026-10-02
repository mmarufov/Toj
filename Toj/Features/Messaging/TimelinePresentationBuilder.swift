import Foundation

nonisolated struct TimelinePresentationInput: Sendable {
    let id: String
    let mine: Bool
    let senderId: String?
    let timestamp: String?

    init(id: String, mine: Bool, senderId: String? = nil, timestamp: String?) {
        self.id = id
        self.mine = mine
        self.senderId = senderId
        self.timestamp = timestamp
    }
}

nonisolated struct TimelinePresentationMetadata: Sendable {
    let id: String
    let dayLabel: String?
    let timestampLabel: String?
    let mediaTimestampLabel: String?
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
}

/// Performs timestamp parsing and row grouping away from the main actor. The returned records are
/// immutable presentation data, so SwiftUI row bodies do no date parsing or neighbor scans.
nonisolated enum TimelinePresentationBuilder {
    static func build(
        _ inputs: [TimelinePresentationInput],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TimelinePresentationMetadata] {
        guard !inputs.isEmpty else { return [] }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let dates = inputs.map { input in
            input.timestamp.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) } ?? now
        }

        return inputs.indices.map { index in
            let firstInGroup = index == inputs.startIndex || !sameGroup(
                inputs[index - 1], inputs[index], dates[index - 1], dates[index], calendar: calendar
            )
            let lastInGroup = index == inputs.index(before: inputs.endIndex) || !sameGroup(
                inputs[index], inputs[index + 1], dates[index], dates[index + 1], calendar: calendar
            )
            let startsDay = index == inputs.startIndex
                || !calendar.isDate(dates[index], inSameDayAs: dates[index - 1])
            return TimelinePresentationMetadata(
                id: inputs[index].id,
                dayLabel: startsDay ? dayLabel(dates[index], now: now, calendar: calendar) : nil,
                timestampLabel: inputs[index].timestamp == nil
                    ? nil
                    : dates[index].formatted(date: .omitted, time: .shortened),
                mediaTimestampLabel: inputs[index].timestamp == nil
                    ? nil
                    : mediaTimestamp(dates[index], now: now, calendar: calendar),
                isFirstInGroup: firstInGroup,
                isLastInGroup: lastInGroup
            )
        }
    }

    private static func sameGroup(
        _ earlier: TimelinePresentationInput,
        _ later: TimelinePresentationInput,
        _ earlierDate: Date,
        _ laterDate: Date,
        calendar: Calendar
    ) -> Bool {
        earlier.mine == later.mine
            && (earlier.mine || earlier.senderId == later.senderId)
            && abs(laterDate.timeIntervalSince(earlierDate)) < 360
            && calendar.isDate(earlierDate, inSameDayAs: laterDate)
    }

    private static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide).day())
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    private static func mediaTimestamp(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "today at \(time)")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "yesterday at \(time)")
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) at \(time)"
    }
}
