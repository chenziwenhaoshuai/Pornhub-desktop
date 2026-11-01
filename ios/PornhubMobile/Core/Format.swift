import Foundation

enum Format {

    /// 秒 -> "1:02:03" / "2:03"
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func bytes(_ value: Int) -> String {
        let number = Double(max(0, value))
        if number < 1024 { return "\(Int(number)) B" }
        if number < 1024 * 1024 { return String(format: "%.0f KB", number / 1024) }
        if number < 1024 * 1024 * 1024 { return String(format: "%.0f MB", number / 1024 / 1024) }
        return String(format: "%.2f GB", number / 1024 / 1024 / 1024)
    }
}
