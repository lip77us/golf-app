//
//  SixesActivity.swift
//  SixesActivity
//
//  The shared contract between the server, the app and the widget
//  (docs/design-review/handoff-sixes-lock/SPEC.md).
//
//  `ContentState` mirrors `services/live_activity.sixes_activity_state` field
//  for field, so an APNs `content-state` payload decodes straight into it and
//  the widget never computes anything about the match. The server decides; the
//  widget renders. Anything derived here would be a second implementation of a
//  rule that already exists in Python, and the two would drift.
//
//  This file needs membership in BOTH targets — the extension renders it and
//  the app hands it to `Activity.request`. Tick Runner in the File Inspector.
//

import ActivityKit
import SwiftUI

// MARK: - The contract

struct SixesActivityAttributes: ActivityAttributes {

    /// Everything that changes during the round. The five slots, plus the one
    /// state that replaces them.
    public struct ContentState: Codable, Hashable {

        struct Header: Codable, Hashable {
            /// `SIXES`, or `SIXES · HIGH-LOW` when that variant is on.
            let game: String
            /// `SEGMENT 2 · HOLES 7-12`, or `EXTRA HOLES · 5-6`.
            let segment: String
        }

        struct Number: Codable, Hashable {
            /// `2 UP` / `ALL SQ` / `+3 PTS`.
            let text: String
            /// `blue` | `orange` | `neutral`.
            let colour: String
        }

        struct Side: Codable, Hashable {
            let names: String
            let colour: String
            let leading: Bool
        }

        struct MatchState: Codable, Hashable {
            /// `DORMIE`, or an em dash. Never the money.
            let word: String
            let toPlay: String

            enum CodingKeys: String, CodingKey {
                case word
                case toPlay = "to_play"
            }
        }

        struct Footer: Codable, Hashable {
            /// `Thru 4 · $5 a match` — round context, which is why thru lives
            /// here and not on the sides line.
            let context: String
            /// `+$5 so far` — the only slot that differs between two phones in
            /// the same group.
            let money: String
        }

        /// The one personal state, on round sign. Replaces the board entirely:
        /// nobody needs a match summary on a lock screen, they need to know who
        /// has the cash.
        struct Final: Codable, Hashable {
            let amount: String      // "+$10"
            let detail: String      // "Blue won 1 and 3"
            let collect: String     // "Collect from Sam"
        }

        let header: Header
        let number: Number
        let sides: [Side]
        let state: MatchState
        /// Three, always — the shape of the round.
        let pips: [String]
        let footer: Footer
        /// Present only on the final state.
        let final: Final?
    }

    /// Fixed for the life of the activity.
    var roundId: Int
    var courseName: String
}

// MARK: - Tokens

/// The packet's palette, and the one place any of it is written down.
enum Sixes {
    static let deepPine = Color(hex: 0x0B1F1A)
    static let pine     = Color(hex: 0x0F6E56)
    /// The app's colour — never a side's. A mint number above a blue row and an
    /// orange row leaves the reader guessing which one is up.
    static let mint     = Color(hex: 0x3BD89A)
    static let muted    = Color(hex: 0x5C6B62)
    static let blue     = Color(hex: 0x5AA7F5)
    static let orange   = Color(hex: 0xF3A059)

    /// A side's colour by the server's name for it. `neutral` is all square —
    /// white, so it belongs to neither side.
    static func side(_ name: String) -> Color {
        switch name {
        case "blue":   return blue
        case "orange": return orange
        default:       return .white.opacity(0.90)
        }
    }

    /// A pip's colour. Won segments wear the winner; the live one is bright;
    /// unplayed is nearly gone. A void segment — voided by a withdrawal —
    /// scores nothing, so it can wear neither side.
    static func pip(_ name: String) -> Color {
        switch name {
        case "blue":   return blue
        case "orange": return orange
        case "halved": return .white.opacity(0.45)
        case "void":   return .white.opacity(0.18)
        case "live":   return .white.opacity(0.62)
        default:       return .white.opacity(0.20)
        }
    }

    // The packet specifies Schibsted Grotesk and Spline Sans. Neither is
    // available here: the app gets them from the `google_fonts` package, which
    // downloads into the Flutter app's own cache at runtime, and a widget
    // extension is a separate process with a separate bundle. Shipping the real
    // faces means adding the .ttf files to THIS target's resources.
    //
    // Until then it is SF, which is what a lock screen renders in anyway. Both
    // faces are routed through here so the swap is two lines, not a sweep.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }
}
