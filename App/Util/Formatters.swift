import Foundation

enum Formatters {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE, MMM d")
        return f
    }()

    /// Sidebar style: "9:41 AM", "Yesterday", "Tuesday", "10/3/26".
    static func listTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return weekday.string(from: date)
        }
        return shortDate.string(from: date)
    }

    /// Transcript separator style: "Today 9:41 AM", "Yesterday 8:00 PM", "Tue, Oct 3 at 9:41 AM".
    static func separator(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today \(time.string(from: date))" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time.string(from: date))" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return "\(weekday.string(from: date)) \(time.string(from: date))"
        }
        return "\(longDate.string(from: date)) at \(time.string(from: date))"
    }

    private static let exactDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE, yMMMd")
        return f
    }()

    /// Find in Chat's results and the chat list's time tooltips: always the full date with the
    /// year, "Tue, Oct 3, 2023 at 9:41 AM".
    static func exact(_ date: Date) -> String {
        "\(exactDate.string(from: date)) at \(time.string(from: date))"
    }

    static func messageTime(_ date: Date) -> String {
        time.string(from: date)
    }
}

extension String {
    /// True for short strings made only of emoji (rendered large, without a bubble).
    var isJumboEmoji: Bool {
        guard !isEmpty, count <= 3 else { return false }
        return allSatisfy { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1)
        }
    }
}
