/// payout_config_field.dart
/// ------------------------
/// Shared "paid places + amounts" widget used in every payout-configuration
/// screen (Match Play setup, wizard Step 4, etc.).
///
/// Key behaviour
/// ~~~~~~~~~~~~~
/// • Integer-only dollar amounts (no pennies).
/// • Paid places stepper 1-4.
/// • Balance row: "Payouts balance ✓" or "Remaining: $N".
/// • Auto-suggest: last place absorbs any rounding remainder so the total
///   always equals the pool exactly.

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Auto-suggest helper (pure function — importable by any screen)
// ---------------------------------------------------------------------------

/// Distribute [pool] dollars across [numPayouts] places using fixed splits.
/// Returns a list of 4 ints (indices beyond numPayouts are 0).
/// The last paid place absorbs any rounding remainder — total is always [pool].
List<int> suggestPayouts(int pool, int numPayouts) {
  if (pool <= 0 || numPayouts < 1) return List.filled(4, 0);
  const splits = <int, List<double>>{
    1: [1.00,  0.00,  0.00,  0.00],
    2: [0.65,  0.35,  0.00,  0.00],
    3: [0.60,  0.25,  0.15,  0.00],
    4: [0.50,  0.25,  0.15,  0.10],
  };
  final s   = splits[numPayouts] ?? [1.0, 0.0, 0.0, 0.0];
  final out = List<int>.filled(4, 0);
  int assigned = 0;
  for (int i = 0; i < numPayouts; i++) {
    if (i == numPayouts - 1) {
      out[i] = pool - assigned;   // remainder — always sums to pool exactly
    } else {
      out[i] = (pool * s[i]).round();
      assigned += out[i];
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

const _placeLabels = ['1st', '2nd', '3rd', '4th'];

/// Consistent payout configuration section.
///
/// The parent owns all four [TextEditingController]s; this widget only reads
/// and writes their text.
///
/// Usage
/// ~~~~~
/// ```dart
/// PayoutConfigField(
///   pool:                 _pool.round(),
///   numPayouts:           _numPayouts,
///   payoutCtrls:          _payoutCtrls,   // List of 4 controllers
///   onNumPayoutsChanged:  (n) => setState(() => _numPayouts = n),
///   onPayoutChanged:      ()  => setState(() {}),
///   onSuggest:            _suggestPayouts,
/// )
/// ```
class PayoutConfigField extends StatelessWidget {
  /// Total prize pool in whole dollars. Pass 0 to hide balance + auto-suggest.
  final int    pool;
  final int    numPayouts;
  /// Must contain exactly 4 controllers.
  final List<TextEditingController> payoutCtrls;
  final void Function(int) onNumPayoutsChanged;
  final void Function()    onPayoutChanged;
  final void Function()    onSuggest;

  const PayoutConfigField({
    super.key,
    required this.pool,
    required this.numPayouts,
    required this.payoutCtrls,
    required this.onNumPayoutsChanged,
    required this.onPayoutChanged,
    required this.onSuggest,
  });

  int get _payoutTotal {
    int sum = 0;
    for (int i = 0; i < numPayouts; i++) {
      sum += int.tryParse(payoutCtrls[i].text.trim()) ?? 0;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final remaining = pool - _payoutTotal;
    final balanced  = remaining == 0 || pool == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Paid-places stepper ──────────────────────────────────────────
        Row(
          children: [
            Text('Paid places:', style: theme.textTheme.bodyMedium),
            const Spacer(),
            IconButton(
              icon:          const Icon(Icons.remove_circle_outline),
              onPressed:     numPayouts > 1
                  ? () {
                      final newN = numPayouts - 1;
                      onNumPayoutsChanged(newN);
                      // When reducing to 1 winner, fill the entire pool.
                      if (newN == 1 && pool > 0) {
                        payoutCtrls[0].text = '$pool';
                        onPayoutChanged();
                      }
                    }
                  : null,
              visualDensity: VisualDensity.compact,
            ),
            SizedBox(
              width: 28,
              child: Text(
                '$numPayouts',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon:          const Icon(Icons.add_circle_outline),
              onPressed:     numPayouts < 4
                  ? () => onNumPayoutsChanged(numPayouts + 1)
                  : null,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 8),

        // ── Amount fields ────────────────────────────────────────────────
        for (int i = 0; i < numPayouts; i++) ...[
          Row(children: [
            SizedBox(
              width: 36,
              child: Text(
                _placeLabels[i],
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller:   payoutCtrls[i],
                decoration:   const InputDecoration(
                  prefixText: '\$ ',
                  border:     OutlineInputBorder(),
                  isDense:    true,
                ),
                keyboardType: TextInputType.number,
                onChanged:    (_) => onPayoutChanged(),
              ),
            ),
          ]),
          const SizedBox(height: 8),
        ],

        // ── Balance + auto-suggest ────────────────────────────────────────
        if (pool > 0) ...[
          const Divider(height: 12),
          Row(children: [
            Expanded(
              child: Text(
                balanced
                    ? 'Payouts balance ✓'
                    : 'Remaining: \$$remaining',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: balanced
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: onSuggest,
              child:     const Text('Auto-suggest'),
            ),
          ]),
        ],
      ],
    );
  }
}
