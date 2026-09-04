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
            /// Optional emphasis on the right-hand label.  Rabbit's extra —
            /// the tail at the end of the round — is the one leg playing for a
            /// different amount, which is what earns it a different colour.
            var accent: String? = nil
            /// `SIXES`, or `SIXES · HIGH-LOW` when that variant is on.
            let game: String
            /// `SEGMENT 2 · HOLES 7-12`, or `EXTRA HOLES · 5-6`.
            let segment: String
        }

        struct Number: Codable, Hashable {
            /// True when the slot holds a word rather than digits — `LOOSE`,
            /// not `+2`.  Derived rather than sent, so no card has to remember
            /// to flag it: a word set at the digits' size shouts, and every
            /// word that lands in this slot is a quiet state.
            var isWord: Bool {
                text.rangeOfCharacter(from: .decimalDigits) == nil
            }

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

        /// Which card this is, and so which layout draws it.
        ///
        /// Optional deliberately: an activity already on someone's lock screen
        /// was started before this field existed, and a decode failure there
        /// is silent — the push is accepted and the board simply stops moving.
        /// Absent means Sixes, which is the only card that shipped without it.
        let kind: String?

        /// Nassau's two matches.  Nothing else uses it, and Nassau uses it
        /// INSTEAD of `number`: two matches are always live — the nine being
        /// played and the eighteen — and there is no honest way to nominate
        /// one of them as a 36px headline.
        struct Row: Codable, Hashable {
            let label: String
            let text: String
            let colour: String
            let note: String
            /// `+2 PRESS`, on the row that owns the bet.  Never in the header:
            /// floating the count to the top would say the round has presses
            /// without saying which match carries them.
            var chip: String? = nil
        }

        /// One row of the Survivor track — a golfer, and what happened to him
        /// on each hole of the Survivor being played.
        ///
        /// Two-dimensional, which is why it is not `pips`: Sixes' three bars
        /// are a 1-D shape and cannot carry a grid.
        struct TrackRow: Codable, Hashable {
            let label: String
            /// `played` | `now` | `fut` | `out` | `gone` | `zom` | `zplay` | `back`
            let cells: [String]
            let isReader: Bool

            enum CodingKeys: String, CodingKey {
                case label, cells
                case isReader = "is_reader"
            }
        }

        let header: Header
        let number: Number
        var rows: [Row]? = nil
        let sides: [Side]
        let state: MatchState

        // ── The shared frame's newer slots ──────────────────────────────────
        // All four are OPTIONAL and belong to the frame, not to one game: the
        // two locked corners are going onto every card in the set, and the
        // ribbon and the who-line with them. Optional so a card that has not
        // adopted them yet simply omits them, and so an activity started by an
        // older build still decodes.

        /// The reader, named — a micro label above the headline.
        var who: String? = nil
        /// `POPPING ON HOLE 13` — the gold band, when the reader gets a stroke
        /// on the hole in play. Gold appears nowhere else in the system, so it
        /// cannot be mistaken for a state. Running states only.
        var ribbon: String? = nil
        /// The locked LOWER-RIGHT corner: `THRU 12 · +7`. Survives the
        /// always-on state, where the stake half of the footer is dropped.
        /// (The locked UPPER-RIGHT rides in `header.segment`.)
        var thru: String? = nil
        /// The Survivor track, and the hole numbers above it.
        var track: [TrackRow]? = nil
        var ruler: [Int]? = nil
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
    /// The mark's cream — the H, its flagstick leg, and the pennant.
    static let cream    = Color(hex: 0xF3F1EA)
    static let blue     = Color(hex: 0x5AA7F5)
    static let orange   = Color(hex: 0xF3A059)
    static let plum     = Color(hex: 0xC9A6E8)

    /// A side's colour by the server's name for it. `neutral` is all square —
    /// white, so it belongs to neither side.
    static func side(_ name: String) -> Color {
        switch name {
        case "blue":   return blue
        case "orange": return orange
        // Rabbit has one distinguished party rather than two sides, so mint is
        // free to mean "holds it" — the thing Sixes could never let it mean.
        case "mint":   return mint
        // Zombieville. #6E4B8E on every light surface, but that is too dark to
        // read against lock-screen glass, so the card uses the lifted plum —
        // one semantic colour with two renderings.
        case "plum":   return plum
        case "dim":    return .white.opacity(0.55)
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
        // Rabbit's run strip: one bar per rabbit, generated from the computed
        // list rather than a fixed three — a round that opens as three can
        // finish as five, so nothing here may be composed as thirds.
        case "mint":       return mint
        case "extra":      return orange.opacity(0.55)
        case "extra-live": return orange
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
