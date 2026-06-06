/// utils/add_halved_golfer.dart
/// Add a golfer who's already on Halved (registered) but not yet in your
/// roster, by phone number. We look the number up, confirm their name +
/// handicap, then create a local golfer carrying that number — so the phone
/// match connects them and their handicap follows. Returns the created
/// [PlayerProfile], or null if cancelled / not found.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';

Future<PlayerProfile?> addHalvedGolferByPhone(BuildContext context) async {
  final auth      = context.read<AuthProvider>();
  final messenger = ScaffoldMessenger.of(context);

  // Step 1 — enter the phone number.
  final phoneCtrl = TextEditingController();
  final phone = await showDialog<String>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: const Text('Add a golfer on Halved'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Enter their phone number. If they're on Halved, we'll pull their "
            'name and handicap.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: phoneCtrl,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone number'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(dctx).pop(phoneCtrl.text.trim()),
            child: const Text('Look up')),
      ],
    ),
  );
  if (phone == null || phone.isEmpty || !context.mounted) return null;

  // Step 2 — look the number up.
  Map<String, dynamic> res;
  try {
    res = await auth.client.lookupHalvedUser(phone);
  } catch (_) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Lookup failed. Please try again.')));
    return null;
  }
  if (!context.mounted) return null;
  if (res['found'] != true) {
    messenger.showSnackBar(const SnackBar(
      content: Text('No Halved member with that number. '
          'Use “Add a golfer” to add them manually.'),
    ));
    return null;
  }

  // Step 3 — confirm.
  final name = (res['name'] as String?) ?? 'this golfer';
  final hcp  = (res['handicap_index'] as String?) ?? '0.0';
  final ok = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: const Text('Add this golfer?'),
      content: Text('$name is on Halved (handicap $hcp). '
          'Add them to your golfers?'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Add')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;

  // Step 4 — create the local golfer (the number makes the connection, and
  // their handicap follows authoritatively).
  try {
    final created = await auth.client.createPlayer(
      name: name,
      handicapIndex: hcp,
      phone: phone,
      sex: (res['sex'] as String?) ?? 'M',
      shortName: res['short_name'] as String?,
    );
    messenger.showSnackBar(SnackBar(content: Text('Added $name.')));
    return created;
  } catch (_) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Could not add golfer.')));
    return null;
  }
}
