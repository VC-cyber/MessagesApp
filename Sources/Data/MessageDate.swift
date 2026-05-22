//
//  MessageDate.swift
//  BetterMessages
//
//  Pure functions for converting between Mac-absolute-time (as stored in
//  `message.date` in chat.db) and Foundation.Date.
//
//  Background — the gotcha:
//    - `message.date` is Mac absolute time: time since 2001-01-01 00:00:00 UTC.
//    - On macOS 10.13+, new rows store NANOSECONDS. Older rows store SECONDS.
//    - The cutoff used everywhere (Apple's own code, our reference scripts,
//      and here): values greater than 1_000_000_000_000 are nanoseconds,
//      otherwise seconds.
//
//  Mac → Unix: add 978307200 (seconds between 2001-01-01 and 1970-01-01 UTC).
//
//  This file has zero dependencies (only Foundation) so it's trivial to unit
//  test in isolation.
//

import Foundation

public enum MessageDate {

    /// Seconds between the Unix epoch (1970-01-01) and the Mac absolute-time
    /// epoch (2001-01-01), in UTC. Add this to a Mac-epoch time (in seconds)
    /// to get a Unix timestamp.
    public static let macEpochOffset: TimeInterval = 978_307_200

    /// Anything strictly greater than this value is interpreted as nanoseconds.
    /// Matches the disambiguation logic in `reference/scripts/*.py`.
    public static let nanosecondThreshold: Int64 = 1_000_000_000_000

    /// Convert a raw `message.date` value (which may be either nanoseconds or
    /// seconds since the Mac epoch) into a `Date`.
    public static func date(fromRaw raw: Int64) -> Date {
        let secondsSinceMacEpoch: TimeInterval
        if raw > nanosecondThreshold {
            secondsSinceMacEpoch = TimeInterval(raw) / 1_000_000_000.0
        } else {
            secondsSinceMacEpoch = TimeInterval(raw)
        }
        return Date(timeIntervalSince1970: secondsSinceMacEpoch + macEpochOffset)
    }

    /// Convert a `Date` to a Mac-absolute-time value in **nanoseconds**.
    /// Use this when writing range predicates against modern (post-10.13) rows.
    public static func nanosecondsSinceMacEpoch(from date: Date) -> Int64 {
        let secondsSinceMacEpoch = date.timeIntervalSince1970 - macEpochOffset
        return Int64(secondsSinceMacEpoch * 1_000_000_000.0)
    }

    /// Convert a `Date` to Mac-absolute-time in **seconds**.
    /// Use this when writing predicates that should also catch pre-10.13 rows.
    public static func secondsSinceMacEpoch(from date: Date) -> TimeInterval {
        return date.timeIntervalSince1970 - macEpochOffset
    }
}
