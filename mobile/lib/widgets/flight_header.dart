/// widgets/flight_header.dart
///
/// The band that says where one flight ends and the next begins.
///
/// **Why it matters more than it looks.** The server has been able to flight a
/// field since Phase 1, and the shipped client drew it correctly by accident —
/// it renders rows in server order and takes `rank` verbatim, so two flights
/// arrived as two ranked blocks with each leader highlighted. What it could not
/// do was say where the seam was, and the stopgap was to carry the letter in
/// the golfer's own name: `A · Paul L`. That was unambiguous and ugly, and it
/// put display text into a field that is a name.
///
/// This is what replaces it, so the name can go back to being a name.
///
/// **The purse is the flight's, and it is the same for every flight.** That is
/// a settled decision rather than an implementation detail: prizes are stated
/// amounts and each flight pays the same table, so the event's budget is the
/// table times the number of flights. Stating it per flight is the whole point
/// of the header — a golfer in B is not playing for a share of one pot, he is
/// playing for a pot of his own.
library;

import 'package:flutter/material.dart';

class FlightHeader extends StatelessWidget {
  /// `A`, `B` — golfers say "I'm in B", never "I'm in flight 2".
  final String label;
  /// How many golfers are on this board.
  final int size;
  /// What this flight pays, in full. Null or zero draws nothing rather than
  /// `$0`, which would read as a flight playing for nothing.
  final double? purse;

  const FlightHeader({
    super.key,
    required this.label,
    required this.size,
    this.purse,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final hasPurse = (purse ?? 0) > 0;
    return Padding(
      // Generous above, tight below: the band belongs to the rows under it,
      // and an even gap either side reads as a divider between two things
      // rather than as the start of one.
      padding: const EdgeInsets.only(top: 14, bottom: 6, left: 2, right: 2),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            '$label FLIGHT',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            hasPurse
                ? '$size ${size == 1 ? 'golfer' : 'golfers'} · '
                  '\$${purse!.toStringAsFixed(0)} in prizes'
                : '$size ${size == 1 ? 'golfer' : 'golfers'}',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
    );
  }
}
