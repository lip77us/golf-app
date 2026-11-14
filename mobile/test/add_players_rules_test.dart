/// The rules behind Add players, against the handoff's own worked examples.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/api/models.dart';
import 'package:golf_mobile/utils/add_players.dart';

PlayerProfile g(int id, String name,
        {String phone = '', String index = '10.0', bool phantom = false}) =>
    PlayerProfile(
      id: id,
      name: name,
      handicapIndex: index,
      isPhantom: phantom,
      email: '',
      phone: phone,
    );

SharedRounds r(int n, [String day = '2026-11-01']) =>
    SharedRounds(n, DateTime.parse(day));

void main() {
  group('name and phone matching', () {
    test('any word of a name that STARTS with the query matches', () {
      expect(nameMatches('Samir Patel', 'pa'), isTrue); // the handoff's case
      expect(nameMatches('Samir Patel', 'sam'), isTrue);
      expect(nameMatches('Samir Patel', 'atel'), isFalse,
          reason: 'inside a word is not a start');
    });

    test('a multi-word query matches consecutive words in order', () {
      expect(nameMatches('Samir Patel', 'sam pat'), isTrue);
      expect(nameMatches('Samir Patel', 'pat sam'), isFalse);
      expect(nameMatches('Mary Ann Lee', 'ann lee'), isTrue);
    });

    test('case does not matter and a blank query matches nothing', () {
      expect(nameMatches('Pete Lane', 'PETE'), isTrue);
      expect(nameMatches('Pete Lane', '  '), isFalse);
    });

    test('three or more digits of a saved mobile match', () {
      expect(phoneMatches('(925) 555-0142', '925555'), isTrue);
      expect(phoneMatches('(925) 555-0142', '555'), isTrue);
      expect(phoneMatches('(925) 555-0142', '55'), isFalse,
          reason: 'two digits is a name search, not a phone one');
      expect(phoneMatches('', '925555'), isFalse);
    });

    test('digits only is a phone search; a letter makes it a name', () {
      expect(looksLikePhone('415 555'), isTrue);
      expect(looksLikePhone('5 iron'), isFalse);
      expect(looksLikePhone('12'), isFalse);
    });
  });

  group('regulars', () {
    final roster = [
      g(1, 'You'),
      g(2, 'Dave'),
      g(3, 'Sam'),
      g(4, 'Al'),
      g(5, 'Pete Lane'),
      g(6, 'Ghost', phantom: true),
      for (var i = 10; i < 20; i++) g(i, 'Golfer $i'),
    ];

    test('the most rounds first, at most seven', () {
      final counts = <int, SharedRounds>{
        for (var i = 10; i < 20; i++) i: r(i - 8),
        2: r(30),
      };
      final regs = regularsOf(roster, counts, meId: 1);
      expect(regs.length, 7);
      expect(regs.first.id, 2);
      final rounds = regs.map((p) => counts[p.id]!.rounds).toList();
      expect(rounds, [...rounds]..sort((a, b) => b.compareTo(a)));
    });

    test('a tie goes to the more recent', () {
      final counts = {2: r(3, '2026-10-01'), 3: r(3, '2026-11-10')};
      expect(regularsOf(roster, counts, meId: 1).map((p) => p.id), [3, 2]);
    });

    test('never you, never a phantom, never someone with no rounds', () {
      final counts = {1: r(9), 6: r(9), 2: r(1)};
      expect(regularsOf(roster, counts, meId: 1).map((p) => p.id), [2]);
    });

    test('a new account has no regulars', () {
      expect(regularsOf(roster, const {}, meId: 1), isEmpty);
    });

    test('a seated regular leaves the grid and the next most played takes his tile',
        () {
      final big = [
        g(1, 'You'),
        for (var i = 2; i <= 10; i++) g(i, 'Golfer $i'),
      ];
      final counts = {for (var i = 2; i <= 10; i++) i: r(100 - i)};
      final before = regularsOf(big, counts, meId: 1);
      expect(before.map((p) => p.id), [2, 3, 4, 5, 6, 7, 8]);
      final after = regularsOf(big, counts, meId: 1, exclude: {2, 3});
      expect(after.map((p) => p.id), [4, 5, 6, 7, 8, 9, 10],
          reason: 'still seven to choose from');
    });

    test('with everyone seated there is nothing left in the grid', () {
      final counts = {2: r(3), 3: r(1)};
      expect(regularsOf(roster, counts, meId: 1, exclude: {2, 3}), isEmpty);
    });

    test('a golfer who is not on the roster cannot be offered', () {
      expect(regularsOf(roster, {999: r(50)}, meId: 1), isEmpty);
    });

    test('the All golfers order is regulars first, then A–Z', () {
      final counts = {3: r(5), 2: r(2)};
      final all = allGolfersOf(roster, counts, meId: 1);
      expect(all.take(2).map((p) => p.id), [3, 2]);
      final rest = all.skip(2).map((p) => p.name.toLowerCase()).toList();
      expect(rest, [...rest]..sort());
      expect(all.map((p) => p.id), isNot(contains(1)));
      expect(all.map((p) => p.id), isNot(contains(6)));
    });
  });

  group('searching your golfers', () {
    final roster = [
      g(1, 'You'),
      g(2, 'Dave Moran', phone: '(415) 555-0101'),
      g(5, 'Pete Lane', phone: '(510) 555-0166'),
      g(7, 'Gabe Ortiz', phone: '(925) 555-0142'),
    ];

    test('finds by name prefix', () {
      final hits = searchYourGolfers(roster, 'p', meId: 1);
      expect(hits.map((p) => p.name), ['Pete Lane']);
    });

    test('finds by phone digits (the handoff: 925555 finds Gabe Ortiz)', () {
      final hits = searchYourGolfers(roster, '925555',
          meId: 1);
      expect(hits.map((p) => p.name), ['Gabe Ortiz']);
    });

    test('regulars are found by search too', () {
      // The handoff kept them out because the grid already showed them. A golfer
      // searched for is wanted now, wherever he is listed.
      final hits = searchYourGolfers(roster, 'dave', meId: 1);
      expect(hits.map((p) => p.name), ['Dave Moran']);
    });

    test('never you, and an empty query finds nothing', () {
      expect(searchYourGolfers(roster, 'you', meId: 1),
          isEmpty);
      expect(searchYourGolfers(roster, '', meId: 1),
          isEmpty);
    });
  });

  group('words', () {
    test('how often you have played', () {
      expect(playedLabel(0), 'not played yet');
      expect(playedLabel(1), 'played once');
      expect(playedLabel(2), 'played twice');
      expect(playedLabel(7), 'played 7 times');
    });

    test('the seats header and its status', () {
      expect(seatsHeader('Skins', 3, 4), 'SKINS · 3 of 4');
      expect(seatsHeader('', 2, 3), '2 of 3');
      expect(seatsStatus(3, 4), 'Add 1 more');
      expect(seatsStatus(4, 4), 'Full');
    });

    test('on My Golfers there is no round to start', () {
      expect(addedToast(firstName: 'Jo', hasNumber: true, viaAccount: false,
          inRound: false), 'Jo added to your golfers.');
      expect(addedToast(firstName: 'Mike', hasNumber: true, viaAccount: true,
          inRound: false), 'Mike added from Halved.');
    });

    test('the toasts', () {
      expect(addedToast(firstName: 'Jo', hasNumber: true, viaAccount: false),
          'Jo added. The game is texted when the round starts.');
      expect(addedToast(firstName: 'Jo', hasNumber: false, viaAccount: false),
          'Jo added as a guest.');
      expect(addedToast(firstName: 'Mike', hasNumber: true, viaAccount: true),
          'Mike added from Halved. A push goes out at Start round.');
    });
  });

  group('the mobile field', () {
    test('formats as digits arrive', () {
      expect(formatMobile('4'), '(4');
      expect(formatMobile('415'), '(415');
      expect(formatMobile('4155'), '(415) 5');
      expect(formatMobile('4155550'), '(415) 555-0');
      expect(formatMobile('4155550100'), '(415) 555-0100');
    });

    test('a pasted country code and punctuation format the same', () {
      expect(formatMobile('+1 415-555-0100'), '(415) 555-0100');
    });

    test('nothing past ten digits', () {
      expect(formatMobile('41555501009999'), '(415) 555-0100');
    });

    test('complete means ten digits', () {
      expect(mobileComplete('(415) 555-0100'), isTrue);
      expect(mobileComplete('(415) 555-010'), isFalse);
      expect(mobileComplete('+1 415 555 0100'), isTrue);
      expect(mobileComplete(''), isFalse);
    });
  });

  group('the new golfer', () {
    test('a name is capitalised, and one name becomes a Guest', () {
      expect(capitalizeName('jo smith'), 'Jo Smith');
      expect(capitalizeName('  jo  '), 'Jo');
      expect(capitalizeName('mcCoy'), 'McCoy');
      expect(savedGuestName('jo'), 'Jo Guest');
      expect(savedGuestName('jo smith'), 'Jo Smith');
      expect(savedGuestName(''), '');
    });

    test('the dark card carries what was typed', () {
      expect(newGolferCardTitle(''), 'Add a new golfer');
      expect(newGolferCardTitle('jo'), 'Add "Jo" as a new golfer');
      expect(newGolferCardTitle('zz'), 'Add "Zz" as a new golfer');
      expect(newGolferCardTitle('415 555 0100'),
          'Add a new golfer with this number');
    });

    test('the sheet opens with the name or the mobile, never both', () {
      expect(newGolferSeed('jo'), (name: 'Jo', mobile: ''));
      expect(newGolferSeed('4155550100'), (name: '', mobile: '(415) 555-0100'));
      expect(newGolferSeed(''), (name: '', mobile: ''));
    });

    test('the one button follows the input', () {
      expect(newGolferButtonLabel('', ''), 'Enter a name');
      expect(newGolferButtonLabel('jo smith', ''), 'Add Jo');
      expect(newGolferButtonLabel('jo smith', '(415) 555-01'), 'Add Jo');
      expect(newGolferButtonLabel('jo smith', '(415) 555-0100'),
          'Add Jo & text the game');
    });

    test('a plus handicap is stored negative', () {
      expect(parseIndexTyped('+2.3'), -2.3);
      expect(parseIndexTyped('12.4'), 12.4);
      expect(parseIndexTyped(''), isNull);
      expect(parseIndexTyped('abc'), isNull);
    });
  });

  group('finding a golfer you already have', () {
    final roster = [
      g(1, 'You'),
      g(2, 'Bill Sinn', phone: '(415) 555-0101'),
      g(3, 'Bill Jones'),
      g(4, 'Jo Guest', phone: '(510) 555-0166'),
      g(5, 'Ghost', phantom: true),
    ];

    List<int> ids(List<DuplicateGolfer> d) => d.map((x) => x.player.id).toList();

    test('the same name is found, ignoring case and spacing', () {
      for (final typed in ['Bill Sinn', 'bill sinn', '  BILL   sinn ']) {
        final d = findDuplicateGolfers(roster, name: typed, mobile: '',
            meId: 1);
        expect(ids(d), [2], reason: typed);
        expect(d.single.byName, isTrue);
      }
    });

    test('a first name alone matches a saved Guest of that name', () {
      // Typing "Jo" would be saved as "Jo Guest", which is who you already have.
      expect(ids(findDuplicateGolfers(roster, name: 'jo', mobile: '', meId: 1)),
          [4]);
    });

    test('a different name, or just the same first name, is not a duplicate',
        () {
      expect(findDuplicateGolfers(roster, name: 'Bill', mobile: '', meId: 1),
          isEmpty,
          reason: '"Bill" alone would be saved as "Bill Guest"');
      expect(
          findDuplicateGolfers(roster, name: 'Bill Smith', mobile: '', meId: 1),
          isEmpty);
    });

    test('the same mobile is found even under a different name', () {
      final d = findDuplicateGolfers(roster,
          name: 'William Sinn', mobile: '4155550101', meId: 1);
      expect(ids(d), [2]);
      expect(d.single.byPhone, isTrue);
      expect(d.single.byName, isFalse);
    });

    test('an incomplete mobile never matches', () {
      expect(
          findDuplicateGolfers(roster, name: 'x', mobile: '(415) 555-01',
              meId: 1),
          isEmpty);
    });

    test('name and mobile together are one golfer, flagged for both', () {
      final d = findDuplicateGolfers(roster,
          name: 'Bill Sinn', mobile: '(415) 555-0101', meId: 1);
      expect(d.length, 1);
      expect(d.single.byName && d.single.byPhone, isTrue);
    });

    test('never you, never a phantom, and nothing typed finds nothing', () {
      expect(findDuplicateGolfers(roster, name: 'You', mobile: '', meId: 1),
          isEmpty);
      expect(findDuplicateGolfers(roster, name: 'Ghost', mobile: '', meId: 1),
          isEmpty);
      expect(findDuplicateGolfers(roster, name: '', mobile: '', meId: 1),
          isEmpty);
    });
  });

  group('the strokes line, against YOUR index', () {
    String say(({String before, String? number, String after}) l) =>
        '${l.before}${l.number ?? ''}${l.after}';

    test('they get strokes from you when their index is higher', () {
      // The handoff's screenshot: a 6-stroke difference.
      final l = strokesLine(yours: 10.0, theirsTyped: '16.0');
      expect(say(l), 'Gets 6 strokes from you.');
      expect(l.number, '6');
    });

    test('they give you strokes when theirs is lower', () {
      expect(say(strokesLine(yours: 10.0, theirsTyped: '8.0')),
          'Gives you 2 strokes.');
    });

    test('one stroke is singular, and level plays you even', () {
      expect(say(strokesLine(yours: 10.0, theirsTyped: '11.0')),
          'Gets 1 stroke from you.');
      expect(say(strokesLine(yours: 10.0, theirsTyped: '10.0')),
          'Plays you even.');
    });

    test('blank says they play off scratch', () {
      expect(say(strokesLine(yours: 10.0, theirsTyped: '')),
          'Leave blank and they play off scratch until it is set.');
    });

    test("the slope scales the difference, on the tee you will play", () {
      // 10 shots of index at slope 130 is ~11.5 -> 12 strokes.
      expect(strokesLine(yours: 0.0, theirsTyped: '10', slope: 130).number,
          '12');
      expect(strokesLine(yours: 0.0, theirsTyped: '10', slope: 113).number,
          '10');
    });

    test('a plus handicap counts as better than scratch', () {
      expect(say(strokesLine(yours: 5.0, theirsTyped: '+2.0')),
          'Gives you 7 strokes.');
    });

    test('with no index of yours there is no strokes claim', () {
      expect(say(strokesLine(yours: null, theirsTyped: '12')), '');
    });
  });
}
