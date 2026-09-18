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
//
// **Every additive field is Optional, and that is not a style choice.**
// Swift's synthesized `init(from:)` IGNORES a property's default value: a
// non-optional `var closed: Bool = false` is a REQUIRED key, and a payload
// without it throws `keyNotFound` — which on a Live Activity is invisible.
// APNs accepts the push, the phone cannot decode the content-state, and iOS
// drops it. No card, no error, nothing in any log.
//
// `closed` shipped that way in 2.9.0 and took down EVERY card on the build,
// for every game, because it sits on ContentState itself. Five more fields
// had the same shape and would have taken down the cards that omit them.
//
// If a field can ever be absent from a payload, it is Optional here. There is
// no second way to spell that.

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
            /// A small chip between the game and the hole — Las Vegas' `CARRY`
            /// while a tie is actually carrying. **A state of the round, not a
            /// setting:** the setting is already readable from the state slot
            /// that created it, and a permanent chip would say the round has
            /// carries without saying which hole is carrying one.
            var chip: String? = nil
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
            /// The dim qualifier that follows the names — Triple Cup's
            /// `· 1 up`, `· 1–0, in the Foursomes`. It sits at 55% beside a
            /// name at full weight, which is what lets a sides line carry a
            /// standing without becoming a second row.
            ///
            /// **The one row is a requirement, not a preference.** A second
            /// sides row is 18pt and puts any card in that packet over the
            /// 160pt ceiling on its own.
            var note: String? = nil
            /// Las Vegas' two-digit hole number, set beside its own side's
            /// name. **The number IS the game** — it had never been drawn
            /// anywhere in the app before the setup screen went in — so it
            /// does not sit at footnote size. It does not get a row of its own
            /// either: a dedicated number row is 24pt and the names were going
            /// on the card regardless. Beside its side it needs no label, and
            /// the pair read as the subtraction the headline came from.
            var figure: String? = nil
            /// The number as it was before a birdie flipped it — `67` struck
            /// through, then `76`. **The swing is shown rather than asserted.**
            var was: String? = nil
        }

        struct MatchState: Codable, Hashable {
            /// `DORMIE`, or an em dash. Never the money.
            let word: String
            let toPlay: String
            /// Optional emphasis on the word. The team cup's decided state —
            /// `BLUE · TAKES IT` — is the one slot in the set that reports an
            /// outcome rather than a position, and it wears mint for it.
            ///
            /// Nowhere else: a word in a side's colour in this slot would be
            /// a second, quieter headline, and the card already has one.
            var colour: String? = nil

            enum CodingKeys: String, CodingKey {
                case word, colour
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
            /// Points only: what this golfer won on the last closed hole —
            /// `Sam Reid 43  5` — answering *who took that one* without a
            /// sentence. It PERSISTS until the next hole closes: the split is
            /// the standing state of the game, not a flash.
            var award: String? = nil
            /// Mint marks **the best award on that hole, never the leader.**
            /// On a tied hole both `4`s go mint and the `1` goes dim; a leader
            /// who scrambled a 3 while somebody else took the 5 reads dim,
            /// which is the column's whole job.
            ///
            /// It sets its own alpha rather than inheriting the row's — a
            /// dimmed row multiplying a dimmed numeral put losing awards near
            /// 30% white, illegible at 10.5px and worse under always-on.
            var awardBest: Bool? = nil
            /// The reader's own row — full weight, where the others sit at
            /// 62%. **Separate from `colour` because they mark different
            /// men:** mint on the total is the LEADER, and the two are usually
            /// not the same golfer. One flag doing both jobs would be wrong in
            /// exactly the state that matters most.
            ///
            /// A WATCHER sets it nowhere, and nothing on his card is bold —
            /// which is the tell that none of it is about him. That falls out
            /// of this rather than needing a case of its own.
            var isReader: Bool? = nil

            enum CodingKeys: String, CodingKey {
                case label, text, colour, note, chip, award
                case awardBest = "award_best"
                case isReader = "is_reader"
            }
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
        /// **The round is over and this is the closing frame.**
        ///
        /// Five of the newer cards sign off by keeping the BOARD and moving
        /// the closing state into its slots, rather than by replacing it with
        /// the three-line `final` card Sixes and Skins use. Both are in the
        /// design record and they answer different questions: a match card's
        /// last word is what you won, while a personal card's last word is
        /// still the number the reader spent four hours on — replacing it
        /// with a figure he cannot check is the thing he least wants at the
        /// 18th.
        ///
        /// The widget needs to know because one size depends on it: Points'
        /// headline is 21 while the rows are the live thing and 26 once the
        /// money is in it. Nothing else reads it yet, and nothing should
        /// unless it has the same kind of reason.
        var closed: Bool? = nil
        /// `POPPING ON HOLE 13` — the gold band, when the reader gets a stroke
        /// on the hole in play. Gold appears nowhere else in the system, so it
        /// cannot be mistaken for a state. Running states only.
        var ribbon: String? = nil
        /// The locked LOWER-RIGHT corner: `THRU 12 · +7`. Survives the
        /// always-on state, where the stake half of the footer is dropped.
        /// (The locked UPPER-RIGHT rides in `header.segment`.)
        var thru: String? = nil
        /// One column of the four-across STRIP — a golfer, his figure, and
        /// what places him.
        ///
        /// **Four names go across, not down.** Four stacked rows of
        /// place/name/score/thru measured 201pt against a 160 ceiling —
        /// clipped on device — and the same four figures per golfer cost 62pt
        /// as a strip. Wolf established it; Stableford's foursome and Stroke
        /// Play's flight proved it retroactively. It is the set's answer to
        /// any four-name card.
        struct StripCol: Codable, Hashable {
            /// `WOLF` / `NEXT` on Wolf; the place (`1ST`) on the personal
            /// cards. Empty draws nothing and keeps the column's height.
            let label: String
            /// SURNAME, caps. A column is about sixty points and a first name
            /// spends it on nothing.
            let name: String
            /// The total, the points, the score to par.
            let figure: String
            /// `thru 11` — under the figure, not beside the name: in a flight
            /// the reader compares positions against different amounts of golf
            /// played, and the pair only means something read together.
            var note: String? = nil
            /// Wolf's side rule under the column: `blue` is the wolf's side,
            /// `orange` the field, absent is unclaimed. A 2px rule rather than
            /// a coloured name — a name at 62% white in orange is unreadable
            /// at a nit, and colouring the figure would collide with mint,
            /// which already means *leads*.
            var rule: String? = nil
            /// The reader: label brighter, name and figure at full weight.
            var isReader: Bool? = nil
            /// Triple Nassau: the two dots in a column head, in pairing
            /// order. **Wolf's columns are people and these are matches**,
            /// which is the whole reason a head needs two of them.
            var dots: [String]? = nil
            /// The figure's own colour — **whoever is winning that match.**
            ///
            /// It is what lets the card never say `DN`. A direction word is
            /// relative to a reader, and in `MORAN·REID` there is no reader
            /// to be relative to: `1 UP` between two other men is meaningless
            /// until you know which. Colour answers it inside the same glyph
            /// that carries the number, and costs no width.
            var colour: String? = nil
            /// A press, as an orange superscript on the figure it doubles —
            /// `+1`. Two-player Nassau put the chip on the row; the row is now
            /// a cell, and that is the difference between *somebody pressed*
            /// and *Moran pressed the back nine against you*. Two presses on
            /// one bet read `+2`, never two chips.
            var chip: String? = nil
            /// Held back, never dropped: the match between the other two men.
            /// **The dimming applies to the SCORE, not to the identity of the
            /// match** — an earlier design had its label at 8px/38%, which
            /// measured 3.04:1 and went invisible under the always-on
            /// reduction, leaving a reader able to see a score with no way to
            /// know whose it was. That is the confusion the card exists to
            /// remove, so the label keeps its size and only the figure dims.
            var dim: Bool? = nil
            /// Ahead — mint, the same rule as every card in the set.
            var isLeader: Bool? = nil

            enum CodingKeys: String, CodingKey {
                case label, name, figure, note, rule, dots, colour, chip, dim
                case isReader = "is_reader"
                case isLeader = "is_leader"
            }
        }

        /// `White` — which tee this golfer plays on the hole in front of him,
        /// and ONLY when he is on a combo set. The name alone: tee names are
        /// colours, so a coloured chip reading "White" asks the eye to
        /// reconcile two at once, and the yardage is on the card already.
        ///
        /// This is a third element on a surface deliberately capped at two. It
        /// earns the space by appearing only for a golfer on a combo — for
        /// everyone else the row is absent and the two-item rule holds exactly.
        /// The server fixes the parent set at setup, so it is present on all
        /// eighteen holes or none.
        var tee: String? = nil
        /// The Survivor track, and the hole numbers above it.
        var track: [TrackRow]? = nil
        var ruler: [Int]? = nil
        /// The four-across strip — Wolf's roster, a Stableford foursome, a
        /// Stroke Play flight. Absent on every card that names two sides.
        var strip: [StripCol]? = nil
        /// **The team cup's needle, instead of `pips`.**
        ///
        /// A casual Triple Cup is four points in a fixed order, so four cells
        /// are the format. A six-group cup is twenty-four, and cells at 320
        /// points would be decoration — so the same 7pt strip becomes one
        /// continuous bar: blue from the left, orange from the right, grey
        /// between them still out.
        ///
        /// **Both are shares of the points AVAILABLE, not of points scored.**
        /// Normalised to points played, the grey band would vanish at the
        /// turn and the centre tick would stop meaning 12½ — which is the
        /// only thing on the card that answers *is it gone*.
        struct Needle: Codable, Hashable {
            let blue: Double
            let orange: Double
        }
        var needle: Needle? = nil
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
    /// Banker's two. **Gold marks the ROLE and does nothing else** — not a
    /// state, not a warning — and amber is the banker's counter-double, the
    /// one event in that game where a golfer's money moves without his
    /// consent. Both are lifted for lock-screen glass, as plum is.
    static let gold     = Color(hex: 0xE8C46A)
    static let amber    = Color(hex: 0xF0C070)

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
        // Banker. Gold is the role — the man facing three bets at once — and
        // amber is his counter. Each means exactly one thing in that game and
        // appears in no other card.
        case "gold":   return gold
        case "amber":  return amber
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
        // Triple Cup's unplayed point. Marginally brighter than the `default`
        // below because four of these sit alone on the card with nothing else
        // in the row to give them an edge.
        case "out":    return .white.opacity(0.17)
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
