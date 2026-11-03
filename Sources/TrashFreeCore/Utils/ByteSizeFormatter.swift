import Foundation

/// Decimal sizes in DaisyDisk's style: "245.1 GB", "6.9 MB", "12 MB", "640 KB".
public enum ByteSizeFormatter {
    private static let units = ["KB", "MB", "GB", "TB", "PB"]

    public static func string(fromByteCount byteCount: Int64) -> String {
        guard byteCount >= 1000 else { return "\(max(byteCount, 0)) bytes" }
        var value = Double(byteCount) / 1000
        var unit = 0
        while value >= 999.95 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let decimals: Int
        switch unit {
        case 0: decimals = 0
        case 1: decimals = value < 10 ? 1 : 0
        default: decimals = 1
        }
        return String(format: "%.\(decimals)f %@", value, units[unit])
    }
}
