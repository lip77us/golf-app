/// screens/team_play_leaderboard_screen.dart
/// -----------------------------------------
/// Six teams, one column (docs/design-review/handoff-team-play/SPEC.md §10.3).
///
/// The Individual board has to carry four rounds, five games and a counting
/// rule. This one carries **one round, one game, six rows** — so the design
/// problem is not how to fit everything but how to resist adding anything.
///
/// It is the same board as everywhere else: rank / team / gross / net, ties
/// marked and drawn adjacent, teams still out marked rather than sorted away.
/// A team is just what sits in the name column. Inventing a bespoke board
/// would mean a golfer who reads three leaderboards a month has to learn a
/// fourth layout to find out he finished fourth.
///
/// **No tabs.** With no side games there is nothing to tab between, and the
/// bar does not sit there empty waiting to be useful.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../utils/golf_colors.dart';
import '../widgets/error_view.dart';
import '../widgets/team_play/team_play_bits.dart';
import '../widgets/team_scorecard.dart';
import 'team_play_settlement_screen.dart';

class TeamPlayLeaderboardScreen extends StatefulWidget {
  final int tournamentId;
  final String tournamentName;

  const TeamPlayLeaderboardScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
  });

  @override
  State<TeamPlayLeaderboardScreen> createState() =>
      _TeamPlayLeaderboardScreenState();
}

class _TeamPlayLeaderboardScreenState extends State<TeamPlayLeaderboardScreen> {
  TeamPlayLeaderboard? _board;
  Object? _error;
  int? _expanded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final board = await context.read<AuthProvider>().client
          .getTeamPlayLeaderboard(widget.tournamentId);
      if (!mounted) return;
      setState(() { _board = board; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = _board;
    return Scaffold(
      backgroundColor: Halved.surface,
      appBar: AppBar(
        backgroundColor: Halved.surface,
        elevation: 0,
        title: Text('Leaderboard', style: Halved.appBarTitle()),
        actions: [
          if (board != null)
            IconButton(
              icon: const Icon(Icons.receipt_long_outlined, color: Halved.pine),
              tooltip: 'Settlement',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TeamPlaySettlementScreen(
                  tournamentId: widget.tournamentId,
                  tournamentName: widget.tournamentName,
                ),
              )),
            ),
        ],
      ),
      body: _error != null
          ? ErrorView(message: '$_error', onRetry: _load)
          : board == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _Header(board: board),
                      const SizedBox(height: 10),
                      for (final team in board.teams)
                        _Row(
                          team    : team,
                          expanded: _expanded == team.foursomeId,
                          onTap   : () => setState(() => _expanded =
                              _expanded == team.foursomeId
                                  ? null : team.foursomeId),
                        ),
                      const SizedBox(height: 16),
                      _Pool(board: board),
                    ],
                  ),
                ),
    );
  }
}

class _Header extends StatelessWidget {
  final TeamPlayLeaderboard board;
  const _Header({required this.board});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            SizedBox(width: 38, child: Text('', style: Halved.label())),
            Expanded(child: Text('TEAM', style: Halved.label())),
            // Named as to-par, because the figures are +2 / E / −3 rather than
            // 74 and 68 — an unlabelled "-3" under "NET" reads as a total.
            SizedBox(width: 52,
                child: Text('GROSS\n TO PAR', textAlign: TextAlign.right,
                    style: Halved.label())),
            SizedBox(width: 52,
                child: Text('NET\nTO PAR', textAlign: TextAlign.right,
                    style: Halved.label())),
          ],
        ),
      );
}

/// `E` / `-3` / `+5` — the app's to-par label, matching the stroke-play board.
String _toPar(int? v) {
  if (v == null) return '—';
  if (v == 0) return 'E';
  return v < 0 ? '$v' : '+$v';
}

class _Row extends StatelessWidget {
  final TeamPlayTeam team;
  final bool expanded;
  final VoidCallback onTap;

  const _Row({required this.team, required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // A team leading through fourteen is not leading, and the board must not
    // let that read as a result.
    final stillOut = !team.complete && team.net != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(Halved.rCard),
        border: Border.all(color: Halved.cardBorder, width: 1.5),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Halved.rCard),
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Row(
                children: [
                  SizedBox(
                    width: 38,
                    child: Text(team.rankLabel,
                        style: Halved.body(weight: FontWeight.w700).copyWith(
                            color: team.tied ? Halved.muted : Halved.deepPine)),
                  ),
                  TeamColourBlock(colour: team.colour, size: 9),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(team.name,
                                  style: Halved.body(weight: FontWeight.w700)),
                            ),
                            if (stillOut) ...[
                              const SizedBox(width: 7),
                              Container(
                                width: 7, height: 7,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Halved.owe,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text('thru ${team.thru}', style: Halved.label()),
                            ],
                          ],
                        ),
                        // Three names against four would look like a mistake;
                        // naming the phantom explains the figure in the space
                        // already there.
                        // Every name, wrapping to a second line rather than
                        // trailing off — three names and an ellipsis tells a
                        // golfer nothing about whether he is on this team.
                        Text(team.memberLine,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Halved.label()),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(_toPar(team.grossToPar),
                        textAlign: TextAlign.right,
                        style: Halved.body(
                            color: toParColor(team.grossToPar) ?? Halved.muted)),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(_toPar(team.netToPar),
                        textAlign: TextAlign.right,
                        style: Halved.sectionHead().copyWith(
                            fontSize: 20,
                            color: toParColor(team.netToPar) ?? Halved.deepPine)),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) _Detail(team: team),
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  final TeamPlayTeam team;
  const _Detail({required this.team});

  @override
  Widget build(BuildContext context) {
    final drive = team.drive;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 0, 13, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 14),
          // No totals line and no roster here: the row above already names
          // every golfer, and the scorecard below carries the numbers. Both
          // were saying it a third time.
          if (team.pars.isNotEmpty) ...[
            // The same widget the entry card draws, so a golfer who has just
            // come off his own scorecard recognises this one. A shamble shows
            // all FOUR balls with the counting ones tinted and the rest pale —
            // the team's total is two of them, and a row showing only the
            // total cannot answer whose scores made it.
            TeamScorecard(
              pars         : team.pars,
              strokeIndexes: team.strokeIndexes,
              rows         : [
                for (final g in team.golfersByHole)
                  TeamScorecardRow(
                    label  : g.shortName,
                    scores : g.scores,
                    strokes: g.strokes,
                    counted: g.counted,
                    italic : g.isPhantom,
                  ),
                // Two lines, because the score the team made and what it was
                // worth are different facts once strokes are involved — a 4 on
                // a stroke hole is level, and one row cannot say both.
                TeamScorecardRow(
                  label  : 'Team',
                  scores : team.scoresByHole,
                  strokes: team.strokesByHole,
                  total  : true,
                ),
                TeamScorecardRow(
                  label  : 'Net',
                  scores : team.netToParByHole,
                  total  : true,
                  toPar  : true,
                ),
              ],
            ),
          ],
          // How much room is left, per window — the figure a captain uses.
          // Per nine has two of them and they do not carry, so each is named.
          for (final w in drive.windows)
            if (w.started || w.owed > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TeamNote(w.freeLabel,
                    warn: w.freeLeft == 0 && w.owed > 0),
              ),
          // No shortfall line here. The free-drives note above already says
          // where the team stands, and a second sentence about the same thing
          // is the row talking twice. The penalty, when the TD chose one, has
          // already moved the gross.
          if (drive.penaltyStrokes > 0) ...[
            const SizedBox(height: 8),
            TeamNote('${drive.penaltyStrokes} penalty strokes added for '
                     'missed drives.'),
          ],
        ],
      ),
    );
  }
}

/// The pool sits UNDER the board, not on it. Money on the rows would put a
/// dollar figure next to a team that has four holes left.
class _Pool extends StatelessWidget {
  final TeamPlayLeaderboard board;
  const _Pool({required this.board});

  @override
  Widget build(BuildContext context) {
    final italic = board.projected;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(Halved.rCard),
        border: Border.all(color: Halved.cardBorder, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Pool — team championship',
                    style: Halved.body(weight: FontWeight.w700)),
              ),
              Text('\$${board.pool.toStringAsFixed(2)}',
                  style: Halved.sectionHead().copyWith(fontSize: 22)),
            ],
          ),
          const SizedBox(height: 8),
          for (final place in board.places)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(width: 34,
                      child: Text(_ordinal(place.place), style: Halved.label())),
                  Expanded(
                    child: Text('${place.pct}% of the pool',
                        style: Halved.body(color: Halved.muted)
                            .copyWith(
                              fontStyle: italic
                                  ? FontStyle.italic : FontStyle.normal,
                            )),
                  ),
                  Text('\$${place.amount.toStringAsFixed(2)}',
                      style: Halved.body(weight: FontWeight.w600).copyWith(
                        fontStyle:
                            italic ? FontStyle.italic : FontStyle.normal,
                      )),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            italic
                ? '\$${board.entryFee.toStringAsFixed(0)} flat × '
                  '${board.golfers} golfers. Money is projected until every '
                  'team has signed for 18.'
                : '\$${board.entryFee.toStringAsFixed(0)} flat × '
                  '${board.golfers} golfers. Split evenly inside the team.',
            style: Halved.body(color: Halved.muted).copyWith(fontSize: 13),
          ),
          if (board.teams.any((t) => t.tied)) ...[
            const SizedBox(height: 8),
            const TeamNote(
              'Tied teams combine the places they occupy and split what those '
              'places pay. No countback.',
            ),
          ],
        ],
      ),
    );
  }

  static String _ordinal(int n) =>
      const ['', '1st', '2nd', '3rd', '4th', '5th', '6th'].elementAtOrNull(n)
          ?? '${n}th';
}
