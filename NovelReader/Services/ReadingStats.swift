//
//  ReadingStats.swift
//  NovelReader
//
//  轻量阅读统计：只落 UserDefaults，不涉及账号与网络。
//  设置页「阅读概览」卡片的数据来源。
//

import Foundation

enum ReadingStats {
    private static let totalKey = "stats.totalMinutes"
    private static let monthKey = "stats.monthMinutes"
    private static let monthTagKey = "stats.monthTag"
    private static let todayKey = "stats.todayMinutes"
    private static let todayTagKey = "stats.todayTag"
    private static let streakKey = "stats.streak"
    private static let lastDayKey = "stats.lastDay"

    private static var calendar: Calendar { Calendar.current }

    private static func dayTag(_ date: Date = Date()) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private static func monthTag(_ date: Date = Date()) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    /// 记一次阅读会话。少于 5 秒的不计，避免误触刷数据。
    static func record(seconds: Double) {
        guard seconds > 5 else { return }
        let minutes = seconds / 60
        let d = UserDefaults.standard

        d.set(d.double(forKey: totalKey) + minutes, forKey: totalKey)

        if d.string(forKey: monthTagKey) != monthTag() {
            d.set(monthTag(), forKey: monthTagKey)
            d.set(0.0, forKey: monthKey)
        }
        d.set(d.double(forKey: monthKey) + minutes, forKey: monthKey)

        if d.string(forKey: todayTagKey) != dayTag() {
            d.set(dayTag(), forKey: todayTagKey)
            d.set(0.0, forKey: todayKey)
        }
        d.set(d.double(forKey: todayKey) + minutes, forKey: todayKey)

        updateStreak(d)
    }

    private static func updateStreak(_ d: UserDefaults) {
        let today = dayTag()
        guard d.string(forKey: lastDayKey) != today else { return }
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        if d.string(forKey: lastDayKey) == dayTag(yesterdayDate) {
            d.set(d.integer(forKey: streakKey) + 1, forKey: streakKey)
        } else {
            d.set(1, forKey: streakKey)
        }
        d.set(today, forKey: lastDayKey)
    }

    static var totalMinutes: Int {
        Int(UserDefaults.standard.double(forKey: totalKey).rounded())
    }

    static var monthMinutes: Int {
        let d = UserDefaults.standard
        guard d.string(forKey: monthTagKey) == monthTag() else { return 0 }
        return Int(d.double(forKey: monthKey).rounded())
    }

    static var todayMinutes: Int {
        let d = UserDefaults.standard
        guard d.string(forKey: todayTagKey) == dayTag() else { return 0 }
        return Int(d.double(forKey: todayKey).rounded())
    }

    static var streak: Int {
        UserDefaults.standard.integer(forKey: streakKey)
    }

    /// "1 分钟" / "1 小时 20 分钟"
    static func text(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分钟"
    }
}
