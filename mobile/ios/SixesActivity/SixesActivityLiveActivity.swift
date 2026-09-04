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
                        } else {
                            SidesView(sides: s.sides)
                        }
                        PipsView(pips: s.pips)
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
    static let known: Set<String> = ["sixes", "rabbit", "nassau", "skins",
                                     "match", "survivor"]

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
                FinalView(header: state.header, final: final)
            } else if state.kind == "rabbit" {
                RabbitBoardView(state: state, isStale: isStale)
            } else if state.kind == "nassau", let rows = state.rows {
                NassauBoardView(state: state, rows: rows, isStale: isStale)
            } else if state.kind == "skins" {
                SkinsBoardView(state: state, isStale: isStale)
            } else if state.kind == "survivor" {
                SurvivorBoardView(state: state, isStale: isStale)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HeaderView(header: state.header)

            HStack(alignment: .top, spacing: 12) {
                // The number and both sides. The number wears the LEADING
                // side's colour so the tie between the score and the side is
                // carried by colour rather than by reading order.
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.number.text)
                        .font(Sixes.display(36, .bold))
                        .tracking(-1)
                        .foregroundStyle(Sixes.side(state.number.colour))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    SidesView(sides: state.sides)
                }
                Spacer(minLength: 0)
                StateView(state: state.state)
            }

            PipsView(pips: state.pips)
            FooterView(footer: state.footer, isStale: isStale)
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
private struct StrokeRibbon: View {
    let text: String

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
            .foregroundStyle(Color(hex: 0x3A2703))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(hex: 0xE9C063), Color(hex: 0xD9A63F)],
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
            FooterView(footer: state.footer, isStale: isStale)
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
            HeaderView(header: state.header)
            NamedOnceView(sides: state.sides)
            ForEach(rows, id: \.label) { MatchRowView(row: $0) }
            FooterView(footer: state.footer, isStale: isStale)
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

            FooterView(footer: state.footer, isStale: isStale)
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
                    Circle()
                        .fill(Sixes.side(side.colour))
                        .frame(width: 5, height: 5)
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
        VStack(alignment: .trailing, spacing: 2) {
            Text(state.word)
                .font(Sixes.display(17, .semibold))
                .foregroundStyle(colour ?? .white.opacity(0.92))
            Text(state.toPlay)
                .font(Sixes.body(9, .bold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.55))
        }
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

/// Round context left, money right. Thru lives here because the headline band
/// holds three things and two of them cannot shrink.
private struct FooterView: View {
    let footer: SixesActivityAttributes.ContentState.Footer
    var isStale: Bool = false

    var body: some View {
        // **A no-stake round removes the footer, not the score.** Gross and
        // thru ride in the header instead (the server moves them), because a
        // row built to end in money whose right edge is permanently blank
        // looks like a failed fetch for eighteen holes.
        //
        // Staleness still claims the row: "no scores in a while" is a fault
        // report, and it outranks a layout rule.
        if isStale || !footer.context.isEmpty || !footer.money.isEmpty {
            HStack {
                Text(isStale ? "No scores in a while" : footer.context)
                    .font(Sixes.body(11))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(footer.money)
                    .font(Sixes.body(11, .semibold))
                    .foregroundStyle(.white.opacity(0.66))
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
private struct FinalView: View {
    let header: SixesActivityAttributes.ContentState.Header
    let final: SixesActivityAttributes.ContentState.Final

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
        }
    }
}
