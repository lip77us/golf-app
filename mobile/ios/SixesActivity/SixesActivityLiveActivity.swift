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
                    VStack(spacing: 5) {
                        SidesView(sides: s.sides)
                        PipsView(pips: s.pips)
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
    /// The only card this build draws.  Grows to a switch when the second one
    /// lands (docs/design-review/handoff-live-activities/SPEC.md).
    static let known = "sixes"

    let state: SixesActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        Group {
            // A card this build does not know how to draw.  Sixes shipped
            // before `kind` existed, so absent means Sixes; anything else
            // named is a layout added after this app was installed, and
            // drawing it as a Sixes board would put one game's numbers under
            // another game's labels.
            if let kind = state.kind, kind != Self.known {
                UnsupportedView(header: state.header)
            } else if let final = state.final {
                FinalView(header: state.header, final: final)
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
                .foregroundStyle(.white.opacity(0.50))
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(state.word)
                .font(Sixes.display(17, .semibold))
                .foregroundStyle(.white.opacity(0.92))
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
        HStack(spacing: 5) {
            ForEach(Array(pips.enumerated()), id: \.offset) { _, pip in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Sixes.pip(pip))
                    .frame(height: 4)
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
