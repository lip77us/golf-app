//
//  SixesActivityLiveActivity.swift
//  SixesActivity
//
//  The Sixes lock screen — five slots, one view, every state
//  (docs/design-review/handoff-sixes-lock/SPEC.md).
//
//  **Build one view; the states are data.** There is no draw state, no waiting
//  card and no "open to draw" button: the pairing changes, the two names change,
//  the pip advances. A push announces it; the activity is already correct.
//
//  **Read-only, deliberately.** No buttons anywhere. Every action in Sixes is
//  group state that wants the app's confirmation, and a lock-screen button on
//  group state strands the other three golfers.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct SixesActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SixesActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                // Faded rather than hidden.  A board nobody has scored on in
                // an hour is still true about the last hole played — it just
                // should not look as live as one that moved a minute ago.
                .opacity(context.isStale ? 0.55 : 1)
                .activityBackgroundTint(Sixes.deepPine.opacity(0.92))
                .activitySystemActionForegroundColor(Sixes.mint)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(s.number.text)
                        .font(Sixes.display(26, .bold))
                        .foregroundStyle(Sixes.side(s.number.colour))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(s.state.word).font(Sixes.display(15, .semibold))
                        Text(s.state.toPlay)
                            .font(Sixes.body(9, .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(s.header.game) · \(s.header.segment)")
                        .font(Sixes.body(9, .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if s.kind == "survivor" {
                            SurvivorSidesView(sides: s.sides)
                        } else if s.kind == "triple_cup" {
                            // Keep it in step with the lock card. The Nassau
                            // expanded island drifted from its own once.
                            CupSidesView(sides: s.sides)
                        } else {
                            SidesView(sides: s.sides)
                        }
                        if let needle = s.needle {
                            CupNeedleView(needle: needle)
                        } else if s.kind == "triple_cup" {
                            CupCellsView(cells: s.pips)
                        } else {
                            PipsView(pips: s.pips)
                        }
                        // Expanded has no locked footer competing for the row,
                        // so the strip and the rows — the shape of the round
                        // on the cards that have one — get drawn here at the
                        // size the lock screen gives them.
                        StripView(strip: s.strip)
                        if s.kind == "points", let rows = s.rows {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(rows.enumerated()),
                                        id: \.offset) { _, row in
                                    PointsRowView(row: row)
                                }
                            }
                        }
                        // **The track lives here**, not on the lock screen.
                        // Expanded has no locked footer competing for the row,
                        // so it gets 11pt cells — larger than it ever had on
                        // the card it was cut from.
                        if let track = s.track, !track.isEmpty {
                            TrackView(rows: track, ruler: s.ruler ?? [],
                                      cellHeight: 11)
                        }
                    }
                }
            } compactLeading: {
                HalvedMark(size: 13)
            } compactTrailing: {
                // What people actually see all round, beside the clock.
                Text(s.number.text)
                    .font(Sixes.display(13, .bold))
                    .foregroundStyle(Sixes.side(s.number.colour))
            } minimal: {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Sixes.mint)
            }
        }
    }
}

// MARK: - The lock screen

private struct LockScreenView: View {
    /// The cards this build can draw
    /// (docs/design-review/handoff-live-activities/SPEC.md).
    /// `match` (singles + fourball) is deliberately absent from the branches
    /// below: it IS the shared composition — header, one number in the leading
    /// side's colour, both sides named, the match word, footer — so it draws
    /// with `BoardView` rather than a layout of its own. Singles and fourball
    /// differ only in how many names sit on a side, which the server has
    /// already joined with an ampersand.
    /// Sequoya 3s draws with `BoardView` too, for the same reason: three
    /// rows, both pairs named, the match word, a footer. What is different
    /// about it — the pairing rotating every third hole, the press riding in
    /// the footer beside the stake — the SERVER has already resolved into the
    /// same five slots, so there is no layout of its own to add.
    ///
    /// The five added with this build — `stableford`, `stroke_play`, `points`,
    /// `wolf`, `triple_cup` — are what lets the server stop gating them. That
    /// order is not optional: a kind leaves the server's `UNSHIPPED_KINDS` in
    /// the commit that bumps the build carrying its layout, never before, or
    /// the first phone without this build draws `UnsupportedView` on a game it
    /// was told it could start.
    static let known: Set<String> = ["sixes", "rabbit", "nassau", "skins",
                                     "match", "survivor", "sequoya", "banker",
                                     "stableford", "stroke_play", "points",
                                     "wolf", "triple_cup"]

    let state: SixesActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        Group {
            // A card this build does not know how to draw.  Sixes shipped
            // before `kind` existed, so absent means Sixes; anything else
            // named is a layout added after this app was installed, and
            // drawing it as a Sixes board would put one game's numbers under
            // another game's labels.
            if let kind = state.kind, !Self.known.contains(kind) {
                UnsupportedView(header: state.header)
            } else if let final = state.final {
                FinalView(header: state.header, final: final,
                          footer: state.footer)
            } else if state.kind == "rabbit" {
                RabbitBoardView(state: state, isStale: isStale)
            } else if state.kind == "nassau", let rows = state.rows {
                NassauBoardView(state: state, rows: rows, isStale: isStale)
            } else if state.kind == "skins" {
                SkinsBoardView(state: state, isStale: isStale)
            } else if state.kind == "survivor" {
                SurvivorBoardView(state: state, isStale: isStale)
            } else if state.kind == "points", let rows = state.rows {
                PointsBoardView(state: state, rows: rows, isStale: isStale)
            } else if state.kind == "triple_cup" {
                TripleCupBoardView(state: state, isStale: isStale)
            } else {
                BoardView(state: state, isStale: isStale)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// The neutral scoreboard — 95% of the round, and identical on all four phones
/// bar the money line.
private struct BoardView: View {
    let state: SixesActivityAttributes.ContentState
    var isStale: Bool = false

    /// **36 unless the card has something better to spend the height on.**
    ///
    /// Wolf drops to 21 because its headline is the PRICE of one hole and the
    /// four totals below it are the standing — a 36px price over a strip of
    /// 18px totals says the hole outranks the round. Every other card here
    /// headlines the figure the game is scored on, and keeps the size.
    ///
    /// Points makes the same call for a different reason and Triple Cup takes
    /// 32; both draw through their own views, so their sizes live there.
    static func headline(_ kind: String?) -> CGFloat {
        kind == "wolf" ? 21 : 36
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // The ribbon belongs to the shared frame, so it hangs off the
            // payload rather than off the kind: Survivor was simply the first
            // card to send one, and Sequoya 3s — where the stroke falls by
            // full course stroke index and can land in the one bet still live
            // — is the second. Cards that never send it are untouched: the row
            // is not drawn at all when the string is absent or empty, so it
            // costs them not even the stack's spacing.
            if let ribbon = state.ribbon, !ribbon.isEmpty {
                StrokeRibbon(text: ribbon,
                             tone: state.kind == "banker" ? "blue" : "gold")
            }
            HeaderView(header: state.header)
            WhoRow(who: state.who)

            // The headline and the state share ONE baseline, and the
            // sides line runs the FULL width beneath both — not inside a
            // left-hand column with the state stacked beside it. The state
            // slot is the shorter element in that row, and hanging it off the
            // top of a 36px numeral left it floating against nothing.
            //
            // The sides line paid for the change: boxed into a column it was
            // competing with the state for width, which is what forces four
            // surnames to shrink on the card that has four of them.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .lastTextBaseline, spacing: 11) {
                    // The number wears the LEADING side's colour so the tie
                    // between the score and the side is carried by colour
                    // rather than by reading order.
                    Text(state.number.text)
                        .font(Sixes.display(Self.headline(state.kind), .bold))
                        .tracking(-1)
                        .foregroundStyle(Sixes.side(state.number.colour))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    StateView(state: state.state)
                }
                SidesView(sides: state.sides)
            }

            PipsView(pips: state.pips)
            StripView(strip: state.strip)
            TeeRow(tee: state.tee)
            FooterView(footer: state.footer, thru: state.thru,
                       isStale: isStale)
        }
    }
}

/// The reader, named — a micro label above the headline.
///
/// **Only on the cards that report a PERSON.** Stableford, Stroke Play and
/// Points headline the reader's own number, and a phone handed round a cart
/// otherwise breaks the assumption that the card is about whoever is holding
/// it. Every card that names two sides sends nothing here and spends no
/// height on it — Survivor's fitted card deleted this row on purpose, 19pt
/// spent telling a man his own name on his own lock screen.
private struct WhoRow: View {
    let who: String?

    var body: some View {
        if let who, !who.isEmpty {
            Text(who.uppercased())
                .font(Sixes.body(9.5, .bold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
        }
    }
}

/// The four-across strip: a golfer per column, and what places him.
///
/// **Four names go across, not down.** Four stacked rows of place / name /
/// score / thru measured 201pt against the 160 ceiling — clipped on device —
/// and the same four figures cost 62pt like this. Wolf established the shape;
/// Stableford's foursome and Stroke Play's flight proved it retroactively, and
/// it is now the set's answer to any four-name card.
///
/// Three cards share it, which is why it is here rather than in any of them.
private struct StripView: View {
    let strip: [SixesActivityAttributes.ContentState.StripCol]?

    var body: some View {
        if let strip, !strip.isEmpty {
            HStack(alignment: .top, spacing: 7) {
                ForEach(Array(strip.enumerated()), id: \.offset) { _, c in
                    StripColumn(col: c)
                }
            }
        }
    }
}

private struct StripColumn: View {
    let col: SixesActivityAttributes.ContentState.StripCol

    /// Mint for a claimed label (Wolf's own seat), otherwise a dim eyebrow.
    /// The reader's label is brighter than the rest without being mint —
    /// mint means *leads* on these cards and must not come to mean two things.
    private var labelColour: Color {
        col.isLeader ? Sixes.mint
            : .white.opacity(col.isReader ? 0.70 : 0.42)
    }

    private var figureColour: Color {
        if col.isLeader || col.isReader { return Sixes.mint }
        return .white.opacity(0.72)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The label slot is always spent, even when empty: the columns are
            // read across, and one starting a row higher than its neighbours
            // makes the figures stop lining up.
            Text(col.label)
                .font(Sixes.body(8.5, .bold))
                .tracking(0.6)
                .foregroundStyle(labelColour)
                .lineLimit(1)
                .frame(height: 11, alignment: .leading)
            Text(col.name)
                .font(Sixes.body(10.5, .bold))
                .foregroundStyle(.white.opacity(col.isReader ? 1 : 0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(col.figure)
                .font(Sixes.display(18, .bold))
                .tracking(-0.5)
                .foregroundStyle(figureColour)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let note = col.note, !note.isEmpty {
                Text(note)
                    .font(Sixes.body(9))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            // The side rule. Under the number, carrying no type, so it
            // survives the always-on pull — and grey is an honest state, not a
            // missing one: before a call, three of these men are about to be
            // on a side and none of them knows which.
            Rectangle()
                .fill(col.rule == nil
                        ? .white.opacity(0.14)
                        : Sixes.side(col.rule!))
                .frame(height: 2)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `TEE · WHITE` — the combo golfer's tee for the hole in front of him.
///
/// **Below a rule rather than beside the status.** Status and strokes are
/// about the bet; the tee is about the next shot, and putting it on the status
/// row would invite reading it as part of the match. The rule is what says
/// they are different subjects.
///
/// Drawn only when the server sends one, which it does only for a golfer on a
/// combo — so on every other card and for every other reader this costs
/// nothing, not even the stack's spacing.
private struct TeeRow: View {
    let tee: String?

    var body: some View {
        if let tee, !tee.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(height: 0.5)
                HStack(spacing: 6) {
                    Text("TEE")
                        .font(Sixes.body(9, .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.45))
                    // A neutral outline, not a green status pill: green is the
                    // app's voice for something happening TO you — strokes,
                    // bets, doubles — and a tee box is a fact about the hole.
                    Text(tee.uppercased())
                        .font(Sixes.body(10.5, .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4,
                                             style: .continuous)
                                .stroke(.white.opacity(0.28), lineWidth: 0.5)
                        )
                    Spacer(minLength: 0)
                }
            }
        }
    }
}




/// Survivor — the headline is a WORD
/// (docs/design-review/handoff-survivor-zombie/README.md, screen 3).
///
/// Every other card opens with a value, because every other game is measured
/// in something: holes, points, skins, dollars. Survivor is measured in
/// whether you are still in it, and that is a word — `ALIVE`, `OUT`, `ZOMBIE`,
/// `BACK IN`. A count of survivors is a GROUP fact and sits in the state slot.
///
/// The strongest case for an activity in the app: you can be knocked out by a
/// shot you did not see. Elimination is a NET comparison, so watching a man
/// hole out does not tell you whether it was you.
private struct SurvivorBoardView: View {
    let state: SixesActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        // The FITTED card — four rows, no track
        // (docs/design-review/handoff-survivor-160pt/README.md).
        //
        // Design measured the built cards rather than estimating, and the
        // finding that decided this layout is worth keeping in front of
        // whoever edits it next: **shrinking the headline word recovers zero
        // height.** The word sits in a row with the state slot, the state slot
        // is 34pt, and the taller item sets the row. Three builds went on
        // taking the word 36 -> 26 -> 22 for height it never bought.
        //
        // The height came from deleting the `who` row (19pt spent telling a
        // man his own name on his own lock screen) and moving the track to the
        // expanded island, where it gets BIGGER cells than it had here.
        //
        // Measured: 135pt running, 153pt with the ribbon, against a ~160 cap.
        VStack(alignment: .leading, spacing: 0) {
            if let ribbon = state.ribbon, !ribbon.isEmpty {
                StrokeRibbon(text: ribbon)
                    .padding(.bottom, 9)
            }

            HeaderView(header: state.header)
                .padding(.bottom, 9)

            HStack(alignment: .bottom, spacing: 11) {
                // 36. Back to the design's size, and it costs nothing: the
                // state slot beside it already sets this row's height.
                Text(state.number.text)
                    .font(Sixes.display(36, .bold))
                    .tracking(-1)
                    .foregroundStyle(Sixes.side(state.number.colour))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                StateView(state: state.state,
                          colour: Sixes.side(state.number.colour))
            }

            SurvivorSidesView(sides: state.sides)
                .padding(.top, 8)

            TeeRow(tee: state.tee)
                .padding(.top, 8)

            SurvivorFooterView(footer: state.footer, thru: state.thru,
                               isStale: isStale)
                .padding(.top, 9)
        }
    }
}

/// The fitted card's sides row — ONE line, not two.
///
/// `Nobody out yet · Paul, Dave, Sam`: the lead phrase carries the state at
/// full weight, the group sits behind it dimmed. The old card spent a row on
/// each and a `who` row above them naming the reader; all three collapse to
/// this, which is most of what got the card under the ceiling.
private struct SurvivorSidesView: View {
    let sides: [SixesActivityAttributes.ContentState.Side]

    var body: some View {
        let lead  = sides.first
        let group = sides.count > 1 ? sides[1].names : ""
        return HStack(spacing: 5) {
            if let lead, !lead.names.isEmpty {
                Text(lead.names)
                    .font(Sixes.body(12.5, .bold))
                    .foregroundStyle(Sixes.side(lead.colour).opacity(
                        lead.colour == "neutral" ? 0.9 : 1))
            }
            if !group.isEmpty {
                Text("·")
                    .font(Sixes.body(12.5))
                    .foregroundStyle(.white.opacity(0.35))
                Text(group)
                    .font(Sixes.body(12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }
}

/// `POPPING ON HOLE 13`. Gold is used nowhere else in the system, which is what
/// stops the band being read as a state.
///
/// **Except on the Banker card**, where gold is already spoken for: it marks
/// the role, and a card where gold means both *banker* and *you are popping*
/// has spent its one loud colour twice. That card's band is blue — a stroke is
/// a fact of the hole rather than an alarm. The tone comes off the card's kind
/// rather than a payload field because the rule belongs to the card, not to
/// the hole it is describing.
private struct StrokeRibbon: View {
    let text: String
    var tone: String = "gold"

    private var fill: [Color] {
        tone == "blue"
            ? [Color(hex: 0xBBD9F7), Color(hex: 0x94C0EE)]
            : [Color(hex: 0xE9C063), Color(hex: 0xD9A63F)]
    }

    private var ink: Color {
        Color(hex: tone == "blue" ? 0x0C2438 : 0x3A2703)
    }

    var body: some View {
        // Drawn INSIDE the content, not bled over the card's edge.
        //
        // The first version chased the design's edge-to-edge band with negative
        // padding: `.padding(.horizontal, 15)` then `-15` cancelled out, and
        // `.padding(.top, -13)` lifted the whole band above the card's content
        // area — where the lock screen's container clips. The server was
        // sending POPPING ON HOLE 8 and nothing appeared on the phone.
        //
        // Escaping a clipping parent needs the shared LockScreenView's padding
        // restructured, which every card would feel. A gold band that is
        // visible beats a perfectly specified one that is not; the bleed can
        // come back with that refactor.
        Text(text)
            .font(Sixes.body(9.5, .bold))
            .tracking(0.5)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: fill,
                                         startPoint: .top, endPoint: .bottom))
            )
    }
}

/// The Survivor being played — a row per golfer, a cell per hole.
///
/// Scoped to one Survivor rather than the round: on a lock screen the only
/// Survivor that can still cost you money is the one you are in, and a
/// round-length track is the leaderboard's job.
///
/// The reader's row is marked by the brighter NAME, not by a colour — the
/// accent belongs to the headline.
private struct TrackView: View {
    let rows: [SixesActivityAttributes.ContentState.TrackRow]
    let ruler: [Int]
    /// 11 in the expanded island, which has the room. The lock-screen card no
    /// longer draws a track at all.
    var cellHeight: CGFloat = 11

    /// A return is WHITE, not mint. Mint is the reader's colour on this card,
    /// and a return lands on whichever row it happened to — mint would mean
    /// his good fortune on one row and his opponent's on the next. White says
    /// *the round turned here* and leaves who it turned for to the row.
    private func fill(_ cell: String) -> Color {
        switch cell {
        case "now":   return .white.opacity(0.34)
        case "out":   return Sixes.orange
        case "zom":   return Sixes.plum
        case "back":  return .white
        case "gone", "fut", "zplay": return .clear
        default:      return .white.opacity(0.17)
        }
    }

    private func stroke(_ cell: String) -> Color {
        switch cell {
        case "now":   return .white.opacity(0.55)
        case "fut":   return .white.opacity(0.12)
        case "zplay": return Sixes.plum
        case "back":  return .white.opacity(0.9)
        default:      return .clear
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !ruler.isEmpty {
                HStack(spacing: 3) {
                    Text("").frame(width: 34)
                    ForEach(ruler, id: \.self) { h in
                        Text("\(h)")
                            .font(Sixes.body(9.5, .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            ForEach(rows, id: \.label) { row in
                HStack(spacing: 3) {
                    Text(row.label)
                        .font(Sixes.body(9.5, .bold))
                        .foregroundStyle(.white.opacity(row.isReader ? 0.95 : 0.55))
                        .lineLimit(1)
                        .frame(width: 34, alignment: .leading)
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(fill(cell))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(stroke(cell), lineWidth: 1)
                            )
                            .frame(height: 11)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

/// Stake terms and money left, the locked corner right.
///
/// The fade is on the stake terms ONLY — nesting the money inside it would
/// multiply the opacity and dim the one figure that is the reader's own.
private struct SurvivorFooterView: View {
    let footer: SixesActivityAttributes.ContentState.Footer
    var thru: String? = nil
    var isStale: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(isStale ? "No scores in a while" : footer.context)
                .font(Sixes.body(11))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            if !footer.money.isEmpty {
                Text(footer.money)
                    .font(Sixes.body(11, .semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 8)
            if let thru, !thru.isEmpty {
                // Locked: never wraps, never yields to anything on its left.
                Text(thru)
                    .font(Sixes.body(11, .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// Skins — one number, nobody named
/// (docs/design-review/handoff-live-activities/skins-HANDOFF.md).
///
/// The one card that puts money in the headline, and the packet is explicit
/// that no other may: everyone on the tee is playing for the same pot, so it is
/// not personal and does not break the neutral board. The footer's money IS
/// personal, which is why this is also the only card in the family with a
/// divider — the two figures are different money and should not read as one
/// column.
///
/// The sides slot stays empty of names. In skins the field is the opponent, and
/// naming it would be a list — the thing a lock screen has least room for. What
/// sits there is where the pot came from, which is the reason the number is big.
private struct SkinsBoardView: View {
    let state: SixesActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // The stroke band is the shared FRAME's, not one game's — see
            // BoardView. It hangs off the payload rather than the kind, so a
            // card whose server has not started sending one is untouched: the
            // row is not drawn at all, costing it not even the stack's
            // spacing.
            if let ribbon = state.ribbon, !ribbon.isEmpty {
                StrokeRibbon(text: ribbon)
            }
            HeaderView(header: state.header)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.number.text)
                        .font(Sixes.display(36, .bold))
                        .tracking(-1)
                        .foregroundStyle(Sixes.side(state.number.colour))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let story = state.sides.first {
                        Text(story.names)
                            .font(Sixes.body(11.5))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                Spacer(minLength: 0)
                StateView(state: state.state)
            }

            Rectangle()
                .fill(.white.opacity(0.11))
                .frame(height: 0.5)
            TeeRow(tee: state.tee)
            FooterView(footer: state.footer, thru: state.thru,
                       isStale: isStale)
        }
    }
}

/// Nassau — two matches, two equal rows, no 36px number anywhere
/// (docs/design-review/handoff-live-activities/nassau-HANDOFF.md).
///
/// The second row is paid for by the sides moving up. Sixes restated both
/// pairings on every update because the pairing changed every match; Nassau's
/// are fixed at setup, so naming them once buys the space — and a number can
/// wear its side's colour without the reader ever re-learning which is which.
private struct NassauBoardView: View {
    let state: SixesActivityAttributes.ContentState
    let rows: [SixesActivityAttributes.ContentState.Row]
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // The stroke band is the shared FRAME's, not one game's — see
            // BoardView. It hangs off the payload rather than the kind, so a
            // card whose server has not started sending one is untouched: the
            // row is not drawn at all, costing it not even the stack's
            // spacing.
            if let ribbon = state.ribbon, !ribbon.isEmpty {
                StrokeRibbon(text: ribbon)
            }
            HeaderView(header: state.header)
            NamedOnceView(sides: state.sides)
            ForEach(rows, id: \.label) { MatchRowView(row: $0) }
            TeeRow(tee: state.tee)
            FooterView(footer: state.footer, thru: state.thru,
                       isStale: isStale)
        }
    }
}

/// Both sides on one line, named once. The longest string this design has to
/// hold — four surnames in the 2v2 variant — so it shrinks rather than wraps.
private struct NamedOnceView: View {
    let sides: [SixesActivityAttributes.ContentState.Side]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(sides.enumerated()), id: \.offset) { i, side in
                if i > 0 {
                    Text("v.")
                        .font(Sixes.body(11))
                        .foregroundStyle(.white.opacity(0.40))
                }
                Circle()
                    .fill(Sixes.side(side.colour))
                    .frame(width: 5, height: 5)
                Text(side.names)
                    .font(Sixes.body(12.5, .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.62)
    }
}

/// One match: label, number in the leading side's colour, its press chip, and
/// the state on the right.
private struct MatchRowView: View {
    let row: SixesActivityAttributes.ContentState.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label)
                .font(Sixes.body(9.5, .bold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.52))
                .frame(width: 52, alignment: .leading)

            Text(row.text)
                .font(Sixes.display(25, .bold))
                .tracking(-0.6)
                .foregroundStyle(Sixes.side(row.colour))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let chip = row.chip {
                Text(chip)
                    .font(Sixes.body(8.5, .bold))
                    .foregroundStyle(Sixes.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Sixes.orange.opacity(0.20),
                                in: Capsule())
            }

            Spacer(minLength: 4)

            Text(row.note)
                .font(Sixes.body(9, .bold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// Points 5-3-1 — three rows, and they are the card
/// (`handoff-lock-screens/personal/HANDOFF.md`).
///
/// **Three rows is one more than any other card carries, and it is affordable
/// for the reason the format is: Points is three-handed only.** No partner to
/// name, no side to colour, and the row count can never grow. The nine points
/// are divided rather than earned, so a point you took is a point neither of
/// the others got — a single number cannot describe that state, which is why
/// the rows survived the height audit and the headline did not.
///
/// **The headline gave way, not the rows.** 36px became 21 because the
/// reader's own total already sits three lines below at full weight, so the
/// big number was the only slot on the card repeating something. That is the
/// opposite call to Survivor, where the 36px word was protected — the
/// difference is duplication, not importance.
private struct PointsBoardView: View {
    let state: SixesActivityAttributes.ContentState
    let rows: [SixesActivityAttributes.ContentState.Row]
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let ribbon = state.ribbon, !ribbon.isEmpty {
                StrokeRibbon(text: ribbon, tone: "gold")
            }
            HeaderView(header: state.header)
            WhoRow(who: state.who)

            HStack(alignment: .lastTextBaseline, spacing: 9) {
                // 21 while the rows are the live thing — the headline was
                // duplicating the reader's own row, so it gave way rather
                // than the rows. On the closing card it holds MONEY, which
                // duplicates nothing, so it takes some of the size back. Not
                // all of it: the three rows are still there.
                Text(state.number.text)
                    .font(Sixes.display(state.closed ? 26 : 21, .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Sixes.side(state.number.colour))
                    .lineLimit(1)
                Spacer(minLength: 8)
                StateView(state: state.state)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    PointsRowView(row: row)
                }
            }

            TeeRow(tee: state.tee)
            FooterView(footer: state.footer, thru: state.thru,
                       isStale: isStale)
        }
    }
}

/// `Sam Reid  43  5` — the golfer, his total, and what he just won.
///
/// **Two different marks, and they mean two different things.** The row at
/// full weight is the READER; mint on the total is the LEADER. They are
/// usually different men, and a card that used one mark for both would be
/// unreadable in the state that matters most.
///
/// On a watcher's card nothing is bold at all — the tell that none of it is
/// about him. That falls out for free: no row says it is his.
private struct PointsRowView: View {
    let row: SixesActivityAttributes.ContentState.Row

    private var mine: Bool { row.isReader }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label)
                .font(Sixes.body(12, mine ? .bold : .regular))
                .foregroundStyle(.white.opacity(mine ? 1 : 0.62))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(row.text)
                .font(Sixes.display(12, .bold))
                .monospacedDigit()
                .foregroundStyle(row.colour == "mint"
                                 ? Sixes.mint
                                 : .white.opacity(mine ? 1 : 0.62))
            // The last hole's award. **It sets its own alpha rather than
            // inheriting the row's** — a dimmed row multiplying a dimmed
            // numeral put losing awards near 30% white, illegible at 10.5px
            // and worse under always-on. A fixed width so three single digits
            // form a column rather than three ragged right edges.
            //
            // Mint marks the BEST award on the hole, never the leader: a man
            // who scrambled a 3 while somebody else took the 5 reads dim,
            // which is the column's whole job.
            Text(row.award ?? "")
                .font(Sixes.body(10.5, .bold))
                .monospacedDigit()
                .foregroundStyle(row.awardBest ? Sixes.mint
                                               : .white.opacity(0.62))
                .frame(width: 26, alignment: .trailing)
        }
    }
}

/// Triple Cup — the headline is the CUP SCORE, including `0–0`
/// (`handoff-lock-screens/triple-cup/HANDOFF.md`).
///
/// Triple Cup exists to produce a cup score, and the match in front of you is
/// a way of earning one point in it. Those are different questions, and the
/// smaller slot takes the second one. An earlier design pass swapped them for
/// the Fourball to avoid headlining `0–0` and it was wrong: **a headline that
/// means one thing before the first point and another after is a slot nobody
/// can learn.**
///
/// 32px rather than 36 — the headline here is two numbers and a dash, and it
/// is the widest string any card in the set puts in that slot.
///
/// The sides line is ONE row, always. Holes 13–18 run two Singles at once, and
/// a row each measured 163pt — over the 160 ceiling on its own, before the
/// cells. Surnames buy both matches for nothing.
private struct TripleCupBoardView: View {
    let state: SixesActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let ribbon = state.ribbon, !ribbon.isEmpty {
                StrokeRibbon(text: ribbon, tone: "gold")
            }
            HeaderView(header: state.header)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .lastTextBaseline, spacing: 11) {
                    // Never mint. Mint is the app's colour, not a side's, and
                    // this number belongs to whichever side is ahead — or to
                    // neither, which is what `neutral` draws.
                    Text(state.number.text)
                        .font(Sixes.display(32, .bold))
                        .tracking(-1)
                        .foregroundStyle(Sixes.side(state.number.colour))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    StateView(state: state.state,
                              colour: state.state.colour.map(Sixes.side))
                }
                CupSidesView(sides: state.sides)
            }

            // **Four cells or one needle, never both.** Which one is the
            // difference between the two games this card serves, and the
            // server sends exactly the one that applies.
            if let needle = state.needle {
                CupNeedleView(needle: needle)
            } else {
                CupCellsView(cells: state.pips)
            }
            TeeRow(tee: state.tee)
            FooterView(footer: state.footer, thru: state.thru,
                       isStale: isStale)
        }
    }
}

/// The sides line — entries ACROSS, never down.
///
/// **This is where the card's height comes from.** Holes 13–18 run two
/// Singles at once, and a row each measured 163pt against a 160 ceiling —
/// over on its own, before the strip. Surnames and a dim qualifier put both
/// matches on one line for nothing.
///
/// It is the set's other sides renderer for a reason: `SidesView` stacks,
/// because Sixes and Match restate two pairings that are each long enough to
/// own a row. Here the entries are short by construction and the row count is
/// the constraint, so the axis flips.
private struct CupSidesView: View {
    let sides: [SixesActivityAttributes.ContentState.Side]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(Array(sides.enumerated()), id: \.offset) { _, side in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // Unlike the personal three, this line HAS sides — yours
                    // and theirs — so every entry carries a dot.
                    if !side.colour.isEmpty {
                        Circle()
                            .fill(Sixes.side(side.colour))
                            .frame(width: 5, height: 5)
                    }
                    Text(side.names)
                        .font(Sixes.body(12.5, side.leading ? .bold : .regular))
                        .foregroundStyle(side.leading
                                         ? Sixes.side(side.colour)
                                         : .white.opacity(0.62))
                    // The standing, at 55% beside a name at full weight. That
                    // difference is what lets one line carry two matches and
                    // still read as two things rather than one long string.
                    if let note = side.note, !note.isEmpty {
                        Text(note)
                            .font(Sixes.body(12.5, .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

/// The team cup's needle — the same 7pt strip, without the cells.
///
/// Blue fills from the left, orange from the right, and **the grey between
/// them is genuinely what is still out**: both widths are shares of the
/// points AVAILABLE, not of points scored. Normalised to points played the
/// grey would vanish at the turn and the tick would stop meaning 12½, which
/// is the only thing on the card that answers *is it gone*.
///
/// Discrete cells are dropped here because a six-group cup has twenty-four
/// points, and twenty-four cells across 320 points would be decoration. The
/// casual cup keeps them because four points in a fixed order is its format.
private struct CupNeedleView: View {
    let needle: SixesActivityAttributes.ContentState.Needle

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.17))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Sixes.blue)
                        .frame(width: geo.size.width * max(0, min(1, needle.blue)))
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Sixes.orange)
                        .frame(width: geo.size.width * max(0, min(1, needle.orange)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 7)
        .overlay(alignment: .center) {
            // The same tick as the cells, and it means the same thing: cross
            // it to win the cup, land on it and the cup is halved.
            Rectangle()
                .fill(.white.opacity(0.85))
                .frame(width: 2, height: 15)
                .cornerRadius(1)
        }
    }
}

/// The four points of the cup, and the line that wins it.
///
/// **Four cells are the FORMAT, not a guess.** Fourball, Foursomes and two
/// Singles, in that order, every time — which is exactly why this card can
/// carry a structure graphic where Sixes could not: a Sixes round has no fixed
/// number of matches, so three bars would have been wrong as often as right.
///
/// The tick at the centre is the half. Two of four halves the cup and 2½ wins
/// it, so the line is where the reader's eye goes to answer *is it gone* — a
/// question the four cells alone cannot answer without counting.
private struct CupCellsView: View {
    let cells: [String]

    var body: some View {
        if !cells.isEmpty {
            HStack(spacing: 5) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    CupCell(cell: cell)
                }
            }
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2, height: 15)
                    .cornerRadius(1)
            }
        }
    }
}

private struct CupCell: View {
    let cell: String

    var body: some View {
        Group {
            // A halved point is **both colours, split down the middle** — not
            // the white a halved segment wears elsewhere in the set. Here the
            // half is a point each rather than a point nobody took, and the
            // cell has to show two men getting paid.
            if cell == "halved" {
                LinearGradient(
                    stops: [.init(color: Sixes.blue, location: 0.5),
                            .init(color: Sixes.orange, location: 0.5)],
                    startPoint: .leading, endPoint: .trailing)
            } else {
                Sixes.pip(cell)
            }
        }
        .frame(height: 7)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

/// Rabbit — one holder, no sides, and a number that is a lead rather than a
/// score (docs/design-review/handoff-live-activities/rabbit-HANDOFF.md).
///
/// The run strip is deliberately absent here. It is the only place the shape of
/// the round is drawn, and there is no room for it on the lock card — so it
/// lives in the expanded Dynamic Island and the state slot carries the holes
/// instead.
private struct RabbitBoardView: View {
    let state: SixesActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // The stroke band is the shared FRAME's, not one game's — see
            // BoardView. It hangs off the payload rather than the kind, so a
            // card whose server has not started sending one is untouched: the
            // row is not drawn at all, costing it not even the stack's
            // spacing.
            if let ribbon = state.ribbon, !ribbon.isEmpty {
                StrokeRibbon(text: ribbon)
            }
            HeaderView(header: state.header)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.number.text)
                        // A word in a number's slot: matching the digits' size
                        // makes LOOSE shout, and it is the quietest state on
                        // the card.
                        .font(Sixes.display(state.number.isWord ? 31 : 36,
                                            .bold))
                        .tracking(-1)
                        .foregroundStyle(Sixes.side(state.number.colour))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HolderView(lines: state.sides)
                }
                Spacer(minLength: 0)
                StateView(state: state.state)
            }

            TeeRow(tee: state.tee)
            FooterView(footer: state.footer, thru: state.thru,
                       isStale: isStale)
        }
    }
}

/// The holder on one line and the chasers on the next — or, when nobody holds
/// it, all three dim on one line. There is no leader to name then, and putting
/// somebody first would imply one.
private struct HolderView: View {
    let lines: [SixesActivityAttributes.ContentState.Side]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.names) { line in
                HStack(spacing: 5) {
                    if line.leading {
                        Circle()
                            .fill(Sixes.side(line.colour))
                            .frame(width: 5, height: 5)
                    }
                    Text(line.names)
                        .font(Sixes.body(12.5, line.leading ? .bold : .regular))
                        .foregroundStyle(Sixes.side(line.colour))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }
}

/// The Halved mark — the H whose right leg is a flagstick planted in the cup.
///
/// Drawn rather than shipped as an image. At 12pt a raster of the full logo is
/// mush, a vector stays crisp at any size, and this way the two brand colours
/// come from the same tokens as the rest of the card instead of being baked
/// into a PNG that would drift the next time the palette moves.
///
/// Geometry is lifted straight from `mobile/assets/icon/halved_mark.svg` and
/// normalised against its own bounding box (x 288…956, y 210…880), so the two
/// stay in step: change the SVG and these numbers are what to update.
private struct HalvedMark: View {
    var size: CGFloat = 12

    private static let ox: CGFloat = 288
    private static let oy: CGFloat = 210
    private static let span: CGFloat = 670

    private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - Self.ox) / Self.span * size,
                y: (y - Self.oy) / Self.span * size)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat,
                      _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(origin: pt(x, y),
               size: CGSize(width:  w / Self.span * size,
                            height: h / Self.span * size))
    }

    var body: some View {
        Canvas { ctx, _ in
            // The cup first, so the flagstick reads as standing in it.
            ctx.fill(Path(ellipseIn: rect(582, 796, 240, 84)),
                     with: .color(Sixes.mint))

            var h = Path()
            h.addRect(rect(288, 262, 118, 600))   // thick left leg
            h.addRect(rect(406, 486, 270,  96))   // crossbar
            h.addRect(rect(676, 210,  52, 640))   // right leg = the flagstick
            // The pennant, flown high and breaking right.
            h.move(to:    pt(728, 224))
            h.addLine(to: pt(956, 314))
            h.addLine(to: pt(728, 404))
            h.closeSubpath()
            ctx.fill(h, with: .color(Sixes.cream))
        }
        .frame(width: size, height: size)
    }
}

private struct HeaderView: View {
    let header: SixesActivityAttributes.ContentState.Header

    var body: some View {
        HStack(spacing: 7) {
            HalvedMark(size: 12)
            Text(header.game)
                .font(Sixes.body(10, .bold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.82))
            Spacer(minLength: 4)
            Text(header.segment)
                .font(Sixes.body(10, .semibold))
                .tracking(0.6)
                // Both labels stay on one line: the variant strings here are
                // longer than Sixes' and wrapped the row before it was pinned.
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(header.accent.map(Sixes.side)
                                 ?? .white.opacity(0.50))
        }
    }
}

/// Both pairings, always named. **Never "you are 2 up"** — four golfers read the
/// same string, and the pairing changes at the turn, so a number without a name
/// is unreadable forty minutes later.
///
/// The rows do not reorder when the lead changes; the leader is marked instead.
private struct SidesView: View {
    let sides: [SixesActivityAttributes.ContentState.Side]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sides, id: \.names) { side in
                HStack(spacing: 5) {
                    // The dot marks a SIDE. Triple Cup's line names both
                    // matches in running text — `You v. Naylor · 2 UP · Kelly
                    // v. Reid · 1 DN` — so there is no one side for a dot to
                    // stand for, and it sends an empty colour to say so.
                    if !side.colour.isEmpty {
                        Circle()
                            .fill(Sixes.side(side.colour))
                            .frame(width: 5, height: 5)
                    }
                    Text(side.names)
                        .font(Sixes.body(12, side.leading ? .bold : .regular))
                        .foregroundStyle(side.leading
                                         ? Sixes.side(side.colour)
                                         : .white.opacity(0.60))
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The state of the MATCH, never the money. `DORMIE` is the one fact that
/// changes how the next hole gets played, and it is the word golfers say.
private struct StateView: View {
    let state: SixesActivityAttributes.ContentState.MatchState
    /// The fitted Survivor card colour-matches the count to its headline word.
    /// Nil everywhere else, which keeps every other card exactly as it was.
    var colour: Color? = nil

    var body: some View {
        // **One baseline, not two.** `DORMIE` over `2 TO PLAY` became
        // `DORMIE · 2 TO PLAY`, which is the arrangement Wolf and Triple Cup
        // were drawn with and is now the set's standard — the design packet
        // restated seven delivered cards to match rather than let the five new
        // ones read as a different family.
        //
        // Worth recording what it bought, because it is less than it looks:
        // 17pt, and only on the cards where this slot was the tallest thing in
        // its row, which on most of them it was not. It is here for
        // consistency, not for the height.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(state.word)
                .font(Sixes.display(15, .bold))
                .tracking(0.2)
                .foregroundStyle(colour ?? .white.opacity(0.92))
            Text(state.toPlay)
                .font(Sixes.body(9, .bold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.55))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Three bars: the whole shape of Sixes. **Identical in every state** — the one
/// element that never moves, so the eye learns where to look.
private struct PipsView: View {
    let pips: [String]

    var body: some View {
        // Match play has no pips — there are no segments to shape. An empty
        // HStack still spends the stack's spacing, which reads as a gap the
        // card did not ask for.
        if !pips.isEmpty {
            HStack(spacing: 5) {
                ForEach(Array(pips.enumerated()), id: \.offset) { _, pip in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Sixes.pip(pip))
                        .frame(height: 4)
                }
            }
        }
    }
}

/// Stake terms and money left, **the locked corner right**.
///
/// The lower-right corner is `THRU 12 · +7` on every card in the set — the
/// round behind you, against gross par — and it pairs with the locked
/// upper-right corner that rides in `header.segment`. This view's own comment
/// used to claim thru lived here while the code drew only context and money,
/// so every card that renders through `BoardView` sent the corner and dropped
/// it: Sixes, Sequoya, Banker, Skins, Nassau and Rabbit all shipped without
/// the half of the pair that survives the always-on state. Only Survivor's
/// footer ever drew it.
private struct FooterView: View {
    let footer: SixesActivityAttributes.ContentState.Footer
    var thru: String? = nil
    var isStale: Bool = false

    var body: some View {
        // **A no-stake round removes the footer, not the score.** Gross and
        // thru ride in the header instead (the server moves them), because a
        // row built to end in money whose right edge is permanently blank
        // looks like a failed fetch for eighteen holes.
        //
        // Staleness still claims the row: "no scores in a while" is a fault
        // report, and it outranks a layout rule.
        let hasThru = !(thru ?? "").isEmpty
        if isStale || hasThru || !footer.context.isEmpty
            || !footer.money.isEmpty {
            HStack(spacing: 8) {
                Text(isStale ? "No scores in a while" : footer.context)
                    .font(Sixes.body(11))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                if !footer.money.isEmpty {
                    Text(footer.money)
                        .font(Sixes.body(11, .semibold))
                        .foregroundStyle(.white.opacity(0.66))
                }
                Spacer(minLength: 8)
                if let thru, !thru.isEmpty {
                    // Locked: never wraps, never yields to anything on its
                    // left. Same treatment Survivor's footer already gives it.
                    Text(thru)
                        .font(Sixes.body(11, .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }
}

/// Honest about not knowing, rather than confidently wrong.  A board is money
/// information, and the wrong labels on the right numbers is the worst outcome
/// available to it.
private struct UnsupportedView: View {
    let header: SixesActivityAttributes.ContentState.Header

    var body: some View {
        HStack(spacing: 9) {
            HalvedMark(size: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(header.game)
                    .font(Sixes.body(10, .bold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.82))
                Text("Update Halved to follow this round here")
                    .font(Sixes.body(11))
                    .foregroundStyle(.white.opacity(0.60))
            }
            Spacer(minLength: 0)
        }
    }
}

/// The last state is not a scoreboard. What you won, and who to see.
///
/// **The replacement card, and only five games use it.** Sixes, Skins, Match,
/// Sequoya, Banker and Nassau end with nothing worth keeping — their running
/// frames are match rows and named sides, and when the matches settle there is
/// no board left, just empty slots. The other cards keep theirs: a headline, a
/// state slot and a personal line all still have something to say.
private struct FinalView: View {
    let header: SixesActivityAttributes.ContentState.Header
    let final: SixesActivityAttributes.ContentState.Final
    /// Drawn when there is one. Every card that signs off this way has been
    /// sending a footer and this view was dropping it — Nassau's `The range
    /// has converged` is the line that made that visible, since it is the
    /// card's own argument for why it never needed a special final until now.
    var footer: SixesActivityAttributes.ContentState.Footer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HeaderView(header: header)
            Text(final.amount)
                .font(Sixes.display(36, .bold))
                .tracking(-1)
                .foregroundStyle(Sixes.mint)
            Text(final.detail)
                .font(Sixes.body(12))
                .foregroundStyle(.white.opacity(0.72))
            Text(final.collect)
                .font(Sixes.body(12, .semibold))
                .foregroundStyle(.white.opacity(0.92))
            if let footer, !footer.context.isEmpty || !footer.money.isEmpty {
                FooterView(footer: footer)
            }
        }
    }
}
