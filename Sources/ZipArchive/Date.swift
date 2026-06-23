//
// This source file is part of the swift-zip-archive project
// Copyright (c) 2025-2026 the swift-zip-archive project authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension Date {
    init(msdosTime: UInt16, msdosDate: UInt16) {
        let second = Int((msdosTime & 0x1f) * 2)
        let minute = Int((msdosTime & 0x7e0) >> 5)
        let hour = Int((msdosTime & 0xf800) >> 11)

        let day = Int((msdosDate & 0x1f))
        let month = Int((msdosDate & 0x1e0) >> 5)
        let year = Int(((msdosDate & 0xfe00) >> 9) + 1980)

        guard isValidGregorianDate(year: year, month: month, day: day),
            (0...23).contains(hour),
            (0...59).contains(minute),
            (0...59).contains(second)
        else {
            self = .init(timeIntervalSince1970: 0)
            return
        }

        #if os(WASI)
        let days = daysSinceUnixEpoch(year: year, month: month, day: day)
        self = .init(
            timeIntervalSince1970: TimeInterval(
                days * 86_400
                    + Int64(hour * 3_600)
                    + Int64(minute * 60)
                    + Int64(second)
            )
        )
        #else
        let dateComponents = DateComponents(calendar: .current, year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        self = dateComponents.date ?? .init(timeIntervalSince1970: 0)
        #endif
    }

    func msdosDate() -> (time: UInt16, date: UInt16) {
        #if os(WASI)
        let components = archiveDateComponents
        #else
        let components = Calendar.current.dateComponents([.day, .month, .year, .hour, .minute, .second], from: self)
        #endif

        guard let componentYear = components.year,
            let componentMonth = components.month,
            let componentDay = components.day,
            let componentHour = components.hour,
            let componentMinute = components.minute,
            let componentSecond = components.second
        else {
            return Self.minimumMSDOSDate
        }
        guard componentYear >= 1980 else {
            return Self.minimumMSDOSDate
        }
        guard componentYear <= 2107 else {
            return Self.maximumMSDOSDate
        }

        let year = UInt16(componentYear - 1980)
        let month = UInt16(clamping: componentMonth)
        let day = UInt16(clamping: componentDay)
        let hour = UInt16(clamping: componentHour)
        let minutes = UInt16(clamping: componentMinute)
        let seconds = UInt16(clamping: componentSecond / 2)

        let date = (year << 9) | (month << 5) | day
        let time = (hour << 11) | (minutes << 5) | seconds

        return (time, date)
    }

    private static let minimumMSDOSDate: (time: UInt16, date: UInt16) = (
        time: 0,
        date: 0x0021
    )

    private static let maximumMSDOSDate: (time: UInt16, date: UInt16) = (
        time: 0xbf7d,
        date: 0xff9f
    )
}

/// Validates the calendar portion of a DOS timestamp before conversion.
///
/// DOS fields can encode impossible dates such as February 31. Foundation may
/// normalize those components instead of rejecting them, while the WASI path
/// performs arithmetic directly, so both paths validate the same invariant.
private func isValidGregorianDate(
    year: Int,
    month: Int,
    day: Int
) -> Bool {
    let daysInMonth: Int
    switch month {
    case 1, 3, 5, 7, 8, 10, 12:
        daysInMonth = 31
    case 4, 6, 9, 11:
        daysInMonth = 30
    case 2:
        let isLeapYear =
            year.isMultiple(of: 4)
            && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        daysInMonth = isLeapYear ? 29 : 28
    default:
        return false
    }
    return (1...daysInMonth).contains(day)
}

#if os(WASI)
extension Date {
    /// Returns UTC components without Foundation calendar services, which are
    /// unavailable in browser-hosted WASI runtimes.
    fileprivate var archiveDateComponents: DateComponents {
        let secondsSinceEpoch = timeIntervalSince1970
        guard secondsSinceEpoch.isFinite,
            secondsSinceEpoch >= 315_532_800
        else {
            return DateComponents(year: 1980, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        }
        guard secondsSinceEpoch <= 4_354_819_198 else {
            return DateComponents(year: 2107, month: 12, day: 31, hour: 23, minute: 59, second: 58)
        }

        let wholeSeconds = Int64(secondsSinceEpoch.rounded(.down))
        let days = wholeSeconds / 86_400
        let secondsWithinDay = wholeSeconds % 86_400
        let date = gregorianDate(daysSinceUnixEpoch: days)

        return DateComponents(
            year: date.year,
            month: date.month,
            day: date.day,
            hour: Int(secondsWithinDay / 3_600),
            minute: Int((secondsWithinDay % 3_600) / 60),
            second: Int(secondsWithinDay % 60)
        )
    }
}

/// Converts a Gregorian date to its signed day offset from January 1, 1970.
///
/// ZIP's DOS timestamp range is bounded to 1980 through 2107, so all arithmetic
/// remains comfortably inside `Int64` on 32-bit WASI targets.
private func daysSinceUnixEpoch(year: Int, month: Int, day: Int) -> Int64 {
    var adjustedYear = Int64(year)
    let adjustedMonth = Int64(month)
    if adjustedMonth <= 2 {
        adjustedYear -= 1
    }
    let era = adjustedYear / 400
    let yearOfEra = adjustedYear - era * 400
    let monthOfYear = adjustedMonth + (adjustedMonth > 2 ? -3 : 9)
    let dayOfYear = (153 * monthOfYear + 2) / 5 + Int64(day) - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

/// Converts a Unix-epoch day offset to a Gregorian date without `Calendar`.
///
/// Browser-hosted WASI does not provide Foundation calendar calculations, so
/// archive timestamp decoding uses the inverse of `daysSinceUnixEpoch`.
private func gregorianDate(
    daysSinceUnixEpoch: Int64
) -> (year: Int, month: Int, day: Int) {
    let shiftedDays = daysSinceUnixEpoch + 719_468
    let era = shiftedDays / 146_097
    let dayOfEra = shiftedDays - era * 146_097
    let yearOfEra =
        (dayOfEra
            - dayOfEra / 1_460
            + dayOfEra / 36_524
            - dayOfEra / 146_096) / 365
    var year = yearOfEra + era * 400
    let dayOfYear =
        dayOfEra
        - (365 * yearOfEra
            + yearOfEra / 4
            - yearOfEra / 100)
    let monthPosition = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthPosition + 2) / 5 + 1
    let month = monthPosition + (monthPosition < 10 ? 3 : -9)
    if month <= 2 {
        year += 1
    }
    return (Int(year), Int(month), Int(day))
}
#endif
