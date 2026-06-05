import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../screens/player_form_screen.dart';
import '../widgets/app_drawer.dart'; // shareInvite, shareOriginFrom

/// Invite a (not-on-app) golfer. If their golfer card already has a phone, opens
/// the share sheet directly. If not, first prompts to add their number — because
/// the invited golfer only auto-connects ("On Halved", scorer-eligible, shows in
/// their own "Shared with me") when their card's phone matches the number they
/// sign up with. "Invite anyway" sends the generic (blind) invite.
Future<void> inviteGolfer(BuildContext context, PlayerProfile golfer) async {
  final auth      = context.read<AuthProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final origin    = shareOriginFrom(context);
  final navigator = Navigator.of(context);

  Future<void> share(String name) =>
      shareInvite(auth, messenger, origin: origin, inviteeName: name);

  if (golfer.phone.trim().isNotEmpty) {
    await share(golfer.name);
    return;
  }

  final choice = await showDialog<String>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text('Invite ${golfer.name}'),
      content: Text(
        "Add ${golfer.name}'s phone number so they automatically connect to "
        'this golfer when they join Halved. You can also invite without it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dctx).pop('invite'),
          child: const Text('Invite anyway'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dctx).pop('add'),
          child: const Text('Add number'),
        ),
      ],
    ),
  );

  if (choice == 'invite') {
    await share(golfer.name);
  } else if (choice == 'add') {
    final updated = await navigator.push<PlayerProfile>(
      MaterialPageRoute(builder: (_) => PlayerFormScreen(player: golfer)),
    );
    if (updated != null && updated.phone.trim().isNotEmpty) {
      await share(updated.name);
    }
  }
}
