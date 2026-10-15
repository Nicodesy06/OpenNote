import SwiftUI
import UIKit

extension Color {
    /// Colore da stringa esadecimale "#RRGGBB".
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)
        if value.count != 6 { rgb = 0x3B6FD8 }
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.calendar?.locale = Locale(identifier: "it_IT")
        return formatter.string(from: seconds) ?? duration(seconds)
    }

    static func date(_ date: Date, time: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = time ? .short : .none
        return formatter.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func usd(_ value: Double) -> String {
        value < 0.01 ? "< 0,01 $" : String(format: "%.2f $", value).replacingOccurrences(of: ".", with: ",")
    }
}

/// Palette e icone delle materie.
enum SubjectStyle {
    static let colors: [String] = [
        "#3B6FD8", "#5E5CE6", "#AF52DE", "#E0467C", "#E5484D", "#F2994A",
        "#E3B341", "#34A853", "#1BA39C", "#2D9CDB", "#6E7B8B", "#8D6E63"
    ]

    static let icons: [String] = [
        "book.closed", "books.vertical", "graduationcap", "building.columns", "paintpalette", "pencil.and.ruler",
        "function", "sum", "atom", "flask", "leaf", "globe.europe.africa",
        "music.note", "theatermasks", "camera", "laptopcomputer", "cpu", "chart.bar",
        "scalemass", "brain.head.profile", "heart.text.square", "cross.case", "hammer", "building.2",
        "map", "text.book.closed", "quote.bubble", "lightbulb", "puzzlepiece", "star"
    ]
}

/// Messaggi di errore leggibili.
extension Error {
    var readableMessage: String {
        if let localized = self as? LocalizedError, let description = localized.errorDescription { return description }
        return localizedDescription
    }
}
