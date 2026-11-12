import Foundation

/// Which painting a day gets. The Mac and the iPhone each work this out from the date,
/// so they show the same painting without talking to each other.
enum DailyPick {
    /// Days since 1970-01-01 for the local calendar date.
    static func day(for date: Date = Date()) -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return Int(utc.date(from: parts)!.timeIntervalSince1970 / 86_400)
    }

    /// 1-based position in the pool. A stride coprime with the pool size visits every
    /// position once before repeating, and 0.618 of the pool keeps neighbouring days far apart.
    static func position(day: Int, total: Int) -> Int {
        var stride = (total * 618 / 1000) | 1
        while gcd(stride, total) != 1 { stride += 1 }
        return (day * stride) % total + 1
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}
