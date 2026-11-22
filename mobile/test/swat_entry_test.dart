import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_mobile/widgets/swat_entry.dart';

Map<String, dynamic> _card({String state = 'open', bool waiting = false}) => {
      'hole': 3, 'ordinal': '3rd',
      'team': {'id': 1, 'name': 'Team Brandt', 'size': 3, 'three': true, 'five': false},
      'phantom': {'state': state, 'score': state == 'open' ? 5 : null},
      'complete': true, 'waiting': waiting, 'best': waiting ? null : 4,
      'balls': waiting ? [] : [
        {'label': 'Kelly', 'gross': 4, 'counts': true, 'tied': false},
        {'label': 'Phantom', 'gross': 5, 'counts': false, 'tied': false},
      ],
      'waiting_note': waiting ? 'The phantom has to score 3 or better to count.' : null,
      'versus': {'teams': 3, 'won': 1, 'lost': 1, 'halved': 0,
                 'to_play': ['Team Kerr'], 'still_to_play': 1, 'waiting': waiting},
      'money': {'team': 24.0, 'each': 8.0, 'split': 'a third each', 'won': 1,
                'lost': 0, 'pushed': 0, 'open': 8,
                'overall': {'up': 1, 'level': 0, 'down': 0}},
    };

Widget _wrap(Widget w) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: w)));

void main() {
  testWidgets('the phantom card shows only a score, never a name', (t) async {
    await t.pumpWidget(_wrap(SwatPhantomCard(card: SwatHoleCard(_card()))));
    expect(find.text('5'), findsOneWidget);
    expect(find.text('Phantom'), findsOneWidget);
  });

  testWidgets('a locked phantom shows a lock and no score', (t) async {
    await t.pumpWidget(_wrap(SwatPhantomCard(card: SwatHoleCard(_card(state: 'locked')))));
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('the tray reports best ball, the hole v the field and money', (t) async {
    await t.pumpWidget(_wrap(SwatHoleTray(
        card: SwatHoleCard(_card()), hole: 3, onEdit: () {}, nextLabel: 'Hole 4')));
    expect(find.text('Counts '), findsOneWidget);
    expect(find.text('THE 3RD AGAINST 3 TEAMS'), findsOneWidget);
    expect(find.text('+\$24'), findsOneWidget);
    expect(find.text('a third each'), findsOneWidget);
  });

  testWidgets('while the phantom is out the counts read as waiting', (t) async {
    await t.pumpWidget(_wrap(SwatHoleTray(
        card: SwatHoleCard(_card(state: 'later', waiting: true)), hole: 3,
        onEdit: () {}, nextLabel: 'Hole 4')));
    expect(find.text('Waiting on the phantom'), findsOneWidget);
  });
}
