/// test/api_compatibility_test.dart
/// -------------------------------
/// **The server is deployed ahead of the app, always.** That ordering is what
/// lets a feature's two halves land separately, and it only works while an old
/// client survives a payload it does not fully recognise. The rule and its
/// four exceptions are in `docs/api-compatibility.md`; this is the half a test
/// can hold.
///
/// ## What is asserted, and what deliberately is not
///
/// The doc originally proposed constructing every model from `{}`. That is the
/// WRONG bar, and measuring it is what showed why: **80 of the 159 models
/// refuse an empty map**, all of them on an identity field —
/// `PlayerTotals.playerId` is `j['player_id'] as int` with no default, while
/// every optional field beside it carries `?? 0`. Those models are written
/// correctly. A player row with no `player_id` is not a payload any server
/// sends, and a test demanding tolerance there would need eighty exemptions,
/// which is a list nobody maintains.
///
/// So this asserts the direction that actually carries the risk:
///
///   1. **An unknown key changes nothing** — every model, no exemptions. This
///      is the deploy-server-first case: the server adds a field and the old
///      client must not notice.
///   2. **Every field designed to be absent degrades to its documented
///      default** — written one at a time, each with the reason it exists,
///      because each one is a promise made to a specific shipped build.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';

/// Every `fromJson` in `models.dart`, by name.
///
/// Generated from the source and kept honest by `_everyModelIsRegistered`
/// below — a model added without an entry fails there rather than being
/// silently skipped, which is the failure mode a hand-written list has.
final Map<String, Object Function(Map<String, dynamic>)> _models = {
  'AccountInfo': (j) => AccountInfo.fromJson(j),
  'AuthResult': (j) => AuthResult.fromJson(j),
  'BankerBankedHole': (j) => BankerBankedHole.fromJson(j),
  'BankerBetLine': (j) => BankerBetLine.fromJson(j),
  'BankerByBank': (j) => BankerByBank.fromJson(j),
  'BankerHoleState': (j) => BankerHoleState.fromJson(j),
  'BankerNet': (j) => BankerNet.fromJson(j),
  'BankerPlayerTotal': (j) => BankerPlayerTotal.fromJson(j),
  'BankerReceipt': (j) => BankerReceipt.fromJson(j),
  'BankerReceiptLine': (j) => BankerReceiptLine.fromJson(j),
  'BankerRules': (j) => BankerRules.fromJson(j),
  'BankerSettlement': (j) => BankerSettlement.fromJson(j),
  'BankerSummary': (j) => BankerSummary.fromJson(j),
  'BankerSwing': (j) => BankerSwing.fromJson(j),
  'BankerTransfer': (j) => BankerTransfer.fromJson(j),
  'CasualRoundPlayer': (j) => CasualRoundPlayer.fromJson(j),
  'CasualRoundSummary': (j) => CasualRoundSummary.fromJson(j),
  'CatalogCourse': (j) => CatalogCourse.fromJson(j),
  'ChatMessage': (j) => ChatMessage.fromJson(j),
  'CourseHit': (j) => CourseHit.fromJson(j),
  'CourseInfo': (j) => CourseInfo.fromJson(j),
  'CourseTeeSummary': (j) => CourseTeeSummary.fromJson(j),
  'CupMatch': (j) => CupMatch.fromJson(j),
  'CupPlayer': (j) => CupPlayer.fromJson(j),
  'CupRound': (j) => CupRound.fromJson(j),
  'CupSegmentResult': (j) => CupSegmentResult.fromJson(j),
  'CupTeam': (j) => CupTeam.fromJson(j),
  'FieldPlace': (j) => FieldPlace.fromJson(j),
  'FourballHole': (j) => FourballHole.fromJson(j),
  'FourballMoneyEntry': (j) => FourballMoneyEntry.fromJson(j),
  'FourballSummary': (j) => FourballSummary.fromJson(j),
  'FourballTeamInfo': (j) => FourballTeamInfo.fromJson(j),
  'Foursome': (j) => Foursome.fromJson(j),
  'HoleScoreEntry': (j) => HoleScoreEntry.fromJson(j),
  'HonorsHole': (j) => HonorsHole.fromJson(j),
  'HonorsPlayerTotal': (j) => HonorsPlayerTotal.fromJson(j),
  'HonorsSummary': (j) => HonorsSummary.fromJson(j),
  'InviteInfo': (j) => InviteInfo.fromJson(j),
  'Leaderboard': (j) => Leaderboard.fromJson(j),
  'LowNetChampionshipSetup': (j) => LowNetChampionshipSetup.fromJson(j),
  'MeResult': (j) => MeResult.fromJson(j),
  'Member': (j) => Member.fromJson(j),
  'Membership': (j) => Membership.fromJson(j),
  'MultiSkinsHole': (j) => MultiSkinsHole.fromJson(j),
  'MultiSkinsHoleScore': (j) => MultiSkinsHoleScore.fromJson(j),
  'MultiSkinsPlayerTotal': (j) => MultiSkinsPlayerTotal.fromJson(j),
  'MultiSkinsSummary': (j) => MultiSkinsSummary.fromJson(j),
  'MySkinsPool': (j) => MySkinsPool.fromJson(j),
  'NassauBetResult': (j) => NassauBetResult.fromJson(j),
  'NassauBottomBetResult': (j) => NassauBottomBetResult.fromJson(j),
  'NassauHoleData': (j) => NassauHoleData.fromJson(j),
  'NassauPhantomDonorHole': (j) => NassauPhantomDonorHole.fromJson(j),
  'NassauPhantomInfo': (j) => NassauPhantomInfo.fromJson(j),
  'NassauPlayerInfo': (j) => NassauPlayerInfo.fromJson(j),
  'NassauPressResult': (j) => NassauPressResult.fromJson(j),
  'NassauSummary': (j) => NassauSummary.fromJson(j),
  'PhantomInitResult': (j) => PhantomInitResult.fromJson(j),
  'PlayerProfile': (j) => PlayerProfile.fromJson(j),
  'PlayerTotals': (j) => PlayerTotals.fromJson(j),
  'Points531Hole': (j) => Points531Hole.fromJson(j),
  'Points531HoleEntry': (j) => Points531HoleEntry.fromJson(j),
  'Points531PlayerTotal': (j) => Points531PlayerTotal.fromJson(j),
  'Points531Summary': (j) => Points531Summary.fromJson(j),
  'QuotaNassauHoleResult': (j) => QuotaNassauHoleResult.fromJson(j),
  'QuotaNassauMatchSummary': (j) => QuotaNassauMatchSummary.fromJson(j),
  'QuotaNassauPlayerInfo': (j) => QuotaNassauPlayerInfo.fromJson(j),
  'QuotaNassauSegment': (j) => QuotaNassauSegment.fromJson(j),
  'QuotaNassauSummary': (j) => QuotaNassauSummary.fromJson(j),
  'RabbitHole': (j) => RabbitHole.fromJson(j),
  'RabbitHoleEntry': (j) => RabbitHoleEntry.fromJson(j),
  'RabbitPlayerTotal': (j) => RabbitPlayerTotal.fromJson(j),
  'RabbitSegment': (j) => RabbitSegment.fromJson(j),
  'RabbitSummary': (j) => RabbitSummary.fromJson(j),
  'Round': (j) => Round.fromJson(j),
  'RoundMessagesResult': (j) => RoundMessagesResult.fromJson(j),
  'RoundSummary': (j) => RoundSummary.fromJson(j),
  'Scorecard': (j) => Scorecard.fromJson(j),
  'ScorecardHole': (j) => ScorecardHole.fromJson(j),
  'ScoringRound': (j) => ScoringRound.fromJson(j),
  'SequoyaBet': (j) => SequoyaBet.fromJson(j),
  'SequoyaCalledPress': (j) => SequoyaCalledPress.fromJson(j),
  'SequoyaMatch': (j) => SequoyaMatch.fromJson(j),
  'SequoyaNet': (j) => SequoyaNet.fromJson(j),
  'SequoyaPlayerTotal': (j) => SequoyaPlayerTotal.fromJson(j),
  'SequoyaReceipt': (j) => SequoyaReceipt.fromJson(j),
  'SequoyaReceiptMatch': (j) => SequoyaReceiptMatch.fromJson(j),
  'SequoyaSettlement': (j) => SequoyaSettlement.fromJson(j),
  'SequoyaSide': (j) => SequoyaSide.fromJson(j),
  'SequoyaThreesSummary': (j) => SequoyaThreesSummary.fromJson(j),
  'SequoyaTransfer': (j) => SequoyaTransfer.fromJson(j),
  'SharedRoundSummary': (j) => SharedRoundSummary.fromJson(j),
  'SixesHoleResult': (j) => SixesHoleResult.fromJson(j),
  'SixesSegment': (j) => SixesSegment.fromJson(j),
  'SixesSummary': (j) => SixesSummary.fromJson(j),
  'SixesTeamInfo': (j) => SixesTeamInfo.fromJson(j),
  'SkinsHole': (j) => SkinsHole.fromJson(j),
  'SkinsJunkEntry': (j) => SkinsJunkEntry.fromJson(j),
  'SkinsPlayerTotal': (j) => SkinsPlayerTotal.fromJson(j),
  'SkinsPoolResolve': (j) => SkinsPoolResolve.fromJson(j),
  'SkinsPoolRosterMember': (j) => SkinsPoolRosterMember.fromJson(j),
  'SkinsSummary': (j) => SkinsSummary.fromJson(j),
  'SpotsEntry': (j) => SpotsEntry.fromJson(j),
  'SpotsHole': (j) => SpotsHole.fromJson(j),
  'SpotsPlayerTotal': (j) => SpotsPlayerTotal.fromJson(j),
  'SpotsSummary': (j) => SpotsSummary.fromJson(j),
  'SurvivorHole': (j) => SurvivorHole.fromJson(j),
  'SurvivorHoleEntry': (j) => SurvivorHoleEntry.fromJson(j),
  'SurvivorLeg': (j) => SurvivorLeg.fromJson(j),
  'SurvivorPlayerTotal': (j) => SurvivorPlayerTotal.fromJson(j),
  'SurvivorSummary': (j) => SurvivorSummary.fromJson(j),
  'TeamPlayAllowance': (j) => TeamPlayAllowance.fromJson(j),
  'TeamPlayBallCount': (j) => TeamPlayBallCount.fromJson(j),
  'TeamPlayBlock': (j) => TeamPlayBlock.fromJson(j),
  'TeamPlayCard': (j) => TeamPlayCard.fromJson(j),
  'TeamPlayCardTeam': (j) => TeamPlayCardTeam.fromJson(j),
  'TeamPlayDrive': (j) => TeamPlayDrive.fromJson(j),
  'TeamPlayDriveGolfer': (j) => TeamPlayDriveGolfer.fromJson(j),
  'TeamPlayDriveOption': (j) => TeamPlayDriveOption.fromJson(j),
  'TeamPlayDriveWindow': (j) => TeamPlayDriveWindow.fromJson(j),
  'TeamPlayGolferCard': (j) => TeamPlayGolferCard.fromJson(j),
  'TeamPlayLeaderboard': (j) => TeamPlayLeaderboard.fromJson(j),
  'TeamPlayMember': (j) => TeamPlayMember.fromJson(j),
  'TeamPlayPaidTeam': (j) => TeamPlayPaidTeam.fromJson(j),
  'TeamPlayPayee': (j) => TeamPlayPayee.fromJson(j),
  'TeamPlayPrizeBlock': (j) => TeamPlayPrizeBlock.fromJson(j),
  'TeamPlayRotaHole': (j) => TeamPlayRotaHole.fromJson(j),
  'TeamPlayRound': (j) => TeamPlayRound.fromJson(j),
  'TeamPlaySettlement': (j) => TeamPlaySettlement.fromJson(j),
  'TeamPlayShambleHole': (j) => TeamPlayShambleHole.fromJson(j),
  'TeamPlayShambleRow': (j) => TeamPlayShambleRow.fromJson(j),
  'TeamPlayStanding': (j) => TeamPlayStanding.fromJson(j),
  'TeamPlaySummary': (j) => TeamPlaySummary.fromJson(j),
  'TeamPlayTeam': (j) => TeamPlayTeam.fromJson(j),
  'TeamTournamentSummary': (j) => TeamTournamentSummary.fromJson(j),
  'TeeInfo': (j) => TeeInfo.fromJson(j),
  'ThreePersonMatchSummary': (j) => ThreePersonMatchSummary.fromJson(j),
  'Tournament': (j) => Tournament.fromJson(j),
  'TpmP1HoleEntry': (j) => TpmP1HoleEntry.fromJson(j),
  'TpmPlayerSummary': (j) => TpmPlayerSummary.fromJson(j),
  'TripleCupHole': (j) => TripleCupHole.fromJson(j),
  'TripleCupMatch': (j) => TripleCupMatch.fromJson(j),
  'TripleCupMatchPlayer': (j) => TripleCupMatchPlayer.fromJson(j),
  'TripleCupPlayerHoleScore': (j) => TripleCupPlayerHoleScore.fromJson(j),
  'TripleCupPlayerMoney': (j) => TripleCupPlayerMoney.fromJson(j),
  'TripleCupSummary': (j) => TripleCupSummary.fromJson(j),
  'TripleCupTeamInfo': (j) => TripleCupTeamInfo.fromJson(j),
  'TripleNassauMatch': (j) => TripleNassauMatch.fromJson(j),
  'TripleNassauPlayer': (j) => TripleNassauPlayer.fromJson(j),
  'TripleNassauScHole': (j) => TripleNassauScHole.fromJson(j),
  'TripleNassauSummary': (j) => TripleNassauSummary.fromJson(j),
  'VegasHole': (j) => VegasHole.fromJson(j),
  'VegasPlayer': (j) => VegasPlayer.fromJson(j),
  'VegasSummary': (j) => VegasSummary.fromJson(j),
  'VegasTeamSummary': (j) => VegasTeamSummary.fromJson(j),
  'WolfHole': (j) => WolfHole.fromJson(j),
  'WolfHoleEntry': (j) => WolfHoleEntry.fromJson(j),
  'WolfPlayerTotal': (j) => WolfPlayerTotal.fromJson(j),
  'WolfSummary': (j) => WolfSummary.fromJson(j),
  'WolfTeeSlot': (j) => WolfTeeSlot.fromJson(j)
};

/// Build, and report the OUTCOME rather than the value — a model that throws
/// on a given payload is a legitimate outcome here, and what matters is
/// whether an unknown key changed it.
String _outcome(Object Function(Map<String, dynamic>) build,
                Map<String, dynamic> payload) {
  try {
    return 'ok:${build(payload).runtimeType}';
  } catch (e) {
    return 'throw:${e.runtimeType}';
  }
}

void main() {
  group('**an unknown key changes nothing**', () {
    test('every model ignores a field it has never heard of', () {
      // The server adds a key; a phone built before it existed must behave
      // exactly as it did. Both outcomes are compared, so the 80 models that
      // reject an empty map take part too: they must fail the SAME way, not
      // a new way.
      final changed = <String>[];
      _models.forEach((name, build) {
        final without = _outcome(build, const <String, dynamic>{});
        final with_ = _outcome(build, const <String, dynamic>{
          'a_field_from_a_later_server': 'whatever',
          'another_one': <String, dynamic>{'nested': 1},
        });
        if (without != with_) changed.add('$name: $without -> $with_');
      });
      expect(changed, isEmpty,
          reason: 'these models react to a key they do not know, so the '
              'server cannot add a field without a client release');
    });

    test('the registry covers every fromJson in models.dart', () {
      // A hand-written list silently stops covering things. This reads the
      // source, so a new model is a failure here rather than a gap nobody
      // sees.
      final src = File('lib/api/models.dart').readAsStringSync();
      final found = RegExp(r'factory ([A-Za-z0-9_]+)\.fromJson')
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toSet();
      expect(found.difference(_models.keys.toSet()), isEmpty,
          reason: 'add these to _models — an unregistered model is untested');
      expect(_models.keys.toSet().difference(found), isEmpty,
          reason: 'these no longer exist; remove them');
    });
  });

  // ── The fields that are MEANT to be absent ──────────────────────────────
  //
  // Each of these is a promise to a build that is already on somebody's
  // phone: "when the server says nothing, behave as you did before." They are
  // written one at a time, with the reason, because a default is only correct
  // against a specific shipped behaviour — a loop over them would assert the
  // shape and lose the argument.
  group('**absent means what it meant before**', () {
    test('Foursome.setupEditable defaults TRUE', () {
      // An older server sends neither this nor `setup_edit_note`. Defaulting
      // FALSE would hide Tees & Handicaps and Edit Configuration on every
      // foursome — the whole 3-hole edit window, unreachable, against a
      // server that simply predates it.
      final f = Foursome.fromJson(const {'id': 1, 'group_number': 1});
      expect(f.setupEditable, isTrue);
    });

    test('SurvivorSummary.zombieOption defaults FALSE', () {
      // Deliberately false even though the GAME now defaults true: this is
      // the "the server did not tell us" case, not a default. The summary
      // always carries the key, so absence means an older server, and an
      // older server means the classic game.
      final s = SurvivorSummary.fromJson(const {});
      expect(s.zombieOption, isFalse);
    });

    test('PlayerProfile.isOnApp and isFavorite default FALSE', () {
      // Both are computed per REQUEST from context the single-player
      // endpoints do not pass. An unknown golfer is not on Halved and is
      // nobody's favourite — absence must not promote him.
      final p = PlayerProfile.fromJson(
          const {'id': 1, 'name': 'A', 'short_name': 'A'});
      expect(p.isOnApp, isFalse);
      expect(p.isFavorite, isFalse);
    });

    test('FieldPlace.metric defaults to stroke', () {
      // **The discriminator, and the one that would be worst to get wrong.**
      // One key carries `net_to_par` on a stroke tournament and `points` on a
      // Stableford one; a client reading points as a score against par prints
      // roughly its opposite. An older server sends neither the metric nor
      // the points, so stroke is the only reading that was ever true.
      final p = FieldPlace.fromJson(const {'rank': 2, 'field': 8});
      expect(p.metric, 'stroke');
      expect(p.points, isNull);
      expect(p.hasFigure, isFalse);
    });

    test('Scorecard survives a server with no field standing', () {
      // Its presence is what tells the client this is an individual-play
      // tournament round. Absent, the standing row does not draw — which is
      // exactly what every casual round does.
      final sc = Scorecard.fromJson(const {
        'foursome_id': 1, 'group_number': 1, 'holes': [], 'totals': [],
      });
      expect(sc.fieldStanding, isEmpty);
      expect(sc.scoringMode, isEmpty);
      // 100 rather than 0: a missing allowance is full handicap, and zero
      // would silently score the card gross.
      expect(sc.scoringNetPercent, 100);
    });

    test('TeamPlayCardTeam survives a server with neither new field', () {
      // `player_ids` is what lets a pairs card tell which team the reader
      // plays for. Absent, the row falls back to the card's own golfers and
      // the standing row does not draw.
      final t = TeamPlayCardTeam.fromJson(const {'slot': 1, 'name': 'B & P'});
      expect(t.playerIds, isEmpty);
      expect(t.standing, isNull);
    });
  });
}
