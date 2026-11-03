/// A SPARSE skins pool inside a tournament.
///
/// Paul, 3 Nov 2026, after a 60-player event: *"all of the grouping info is
/// in the 60 person tournament and there is no need to make me redo the
/// groupings as an independent round."*
///
/// `MultiSkinsGame` has always been a ROUND-level pool with an explicit
/// roster; what was missing is that it was never offered on a tournament
/// round, so the only way to run one was to build a separate casual round
/// and re-enter the draw. The watch-link machinery exists only for a CASUAL
/// pool, whose participants play in independent rounds.
///
/// These pin the three things the tournament case does differently, all of
/// which are keyed on one flag and so are all one edit away from being
/// silently undone.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/game_catalog.dart';
import 'package:golf_mobile/widgets/side_games_picker.dart';

void main() {
  group('it is offered on a tournament round', () {
    test('the catalog lists it as a per-round side game', () {
      // This is the whole of the plumbing: `SideGamesPicker` builds from
      // `tournamentRoundGames`, so a game appears in the wizard's round-1
      // step, every later round's setup screen AND the hub's side games
      // screen by carrying `tournament: true` and nothing else.
      final ids = perRoundSideGames(multiFoursome: true).map((g) => g.id);
      expect(ids, contains(GameIds.multiSkins));
    });

    test('and is still a casual game', () {
      // The casual flow is where it started and it is unchanged — a pool
      // spanning independent rounds still links in by watch link.
      expect(gameMeta(GameIds.multiSkins)!.casual, isTrue);
    });

    test('it can explain itself on the card', () {
      final m = gameMeta(GameIds.multiSkins)!;
      expect(m.blurb, isNotNull);
      expect(m.moneyNote, isNotNull);
    });

    testWidgets('the picker draws a switch for it', (t) async {
      final on = <String>{};
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SideGamesPicker(
                selected: on, onToggle: (id, v) {}, multiFoursome: true),
          ),
        ),
      ));
      expect(find.text(gameMeta(GameIds.multiSkins)!.displayName),
          findsOneWidget);
    });

    test('it does not need more than one group', () {
      // The games that require several rank GROUPS against a field. A skins
      // pool ranks golfers, and its own gate is two participants.
      expect(gameMeta(GameIds.multiSkins)!.requiresMultiFoursome, isFalse);
    });
  });

  group('the setup screen knows it is a tournament', () {
    final src =
        File('lib/screens/multi_skins_setup_screen.dart').readAsStringSync();

    test('nobody is ticked by default', () {
      // Sparse is the point: a default of all would mean unticking forty of
      // sixty. The casual default stays all, because there the pool IS the
      // round.
      expect(src, contains('final defaultOn = !_isTournament;'));
    });

    test('every seated golfer is eligible', () {
      // The "needs somebody on Halved on his card" rule is about a casual
      // multi-group round, where each card needs its own scorer. A
      // tournament group already has one — Paul's own distinction — and the
      // server has always agreed: `valid_participant_ids` admits host-round
      // members, login-less included.
      final i = src.indexOf('bool _canJoin(');
      expect(i, greaterThan(0));
      final body = src.substring(i, src.indexOf('canJoinPool(', i));
      expect(body, contains('_isTournament ||'));
    });

    test('no golfer from outside the round is offered', () {
      // He would ante into a pool he has no card in, could never win a skin
      // and could never stop paying. The server refuses him by name.
      expect(src, contains('if (!_isTournamentRound && _externalGolfers'));
    });

    test('the roster is searchable', () {
      // A 60-name list is searched, not read.
      expect(src, contains('_matchesQuery'));
      expect(src, contains("hintText: 'Find a golfer'"));
    });

  });

  group('the hub', () {
    final src = File('lib/screens/round_screen.dart').readAsStringSync();

    test('does not offer to redraw a tournament round', () {
      // "Groups & golfers" re-groups through `setup_round`, which deletes
      // every foursome in the round and rebuilds it. On a tournament round
      // that is the TD's draw, with his pairings and tee times in it.
      expect(src, contains("if (!isComplete && !isTournamentRound)"));
    });

    test('the button says Set up before it says Edit', () {
      // The switch and the roster are two separate moves, so a pool turned
      // on in the create wizard has nothing configured yet.
      expect(src, contains('round.hasSkinsPool'));
    });
  });
}
