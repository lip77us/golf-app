import 'package:flutter/material.dart';
import 'package:halved_sms/halved_sms.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../ui_labels.dart';
import '../providers/auth_provider.dart';
import '../screens/player_form_screen.dart';
import '../widgets/app_drawer.dart'; // shareInvite, shareOriginFrom

/// Invite a (not-on-app) golfer. If their golfer card already has a phone, opens
/// Messages with the recipient + a ready-to-send invite pre-filled (one tap to
/// send, from the user's own phone → TCPA / App Store safe). If not, first
/// prompts to add their number — because the invited golfer only auto-connects
/// ("On Halved", scorer-eligible, sees the round in their own Casual Rounds)
/// when their card's phone matches the number they sign up with. "Invite anyway"
/// sends the generic (blind) invite via the native share sheet.
Future<void> inviteGolfer(BuildContext context, PlayerProfile golfer) async {
  final auth      = context.read<AuthProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final origin    = shareOriginFrom(context);
  final navigator = Navigator.of(context);

  if (golfer.phone.trim().isNotEmpty) {
    await sendGolferSmsInvite(auth, messenger, golfer: golfer);
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
    // No phone on file → fall back to the native share sheet (generic invite).
    await shareInvite(auth, messenger, origin: origin, inviteeName: golfer.name);
  } else if (choice == 'add') {
    final updated = await navigator.push<PlayerProfile>(
      MaterialPageRoute(builder: (_) => PlayerFormScreen(player: golfer)),
    );
    if (updated != null && updated.phone.trim().isNotEmpty) {
      await sendGolferSmsInvite(auth, messenger, golfer: updated);
    }
  }
}

/// After adding a golfer to the My Golfers roster (NOT a round), offer to text
/// them a personalized invite. No-op when the golfer has no phone on file or is
/// already on Halved (nothing to invite). Unlike [maybeOfferRoundSmsInvite] the
/// copy has no round framing — the golfer isn't being added to a round here.
Future<void> maybeOfferGolferSmsInvite(
  BuildContext context,
  PlayerProfile golfer,
) async {
  if (golfer.phone.trim().isEmpty || golfer.isOnApp || !context.mounted) return;
  final auth      = context.read<AuthProvider>();
  final messenger = ScaffoldMessenger.of(context);

  final send = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text('Text ${golfer.name} an invite?'),
      content: Text(
        'Open Messages with a ready-to-send invite to ${golfer.name} '
        '(${golfer.phone.trim()}). When they join Halved and verify this '
        "number, they'll connect to you automatically.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(dctx).pop(true),
          icon: const Icon(Icons.sms_outlined),
          label: const Text('Text invite'),
        ),
      ],
    ),
  );
  if (send != true || !context.mounted) return;
  await sendGolferSmsInvite(auth, messenger, golfer: golfer);
}

/// After inline-adding a golfer during round setup, offer to text them a
/// pre-seeded invite. No-op when the golfer has no phone on file or is already
/// on Halved (nothing to invite). When [courseName] is supplied it's woven into
/// the message so the text names the round.
Future<void> maybeOfferRoundSmsInvite(
  BuildContext context,
  PlayerProfile golfer, {
  String? courseName,
}) async {
  if (golfer.phone.trim().isEmpty || golfer.isOnApp || !context.mounted) return;
  final auth      = context.read<AuthProvider>();
  final messenger = ScaffoldMessenger.of(context);

  final send = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text('Text ${golfer.name} an invite?'),
      content: Text(
        'Open Messages with a ready-to-send invite to ${golfer.name} '
        '(${golfer.phone.trim()}). When they join Halved and verify this '
        "number, they'll see this round in their $kCasualRoundsLabel.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(dctx).pop(true),
          icon: const Icon(Icons.sms_outlined),
          label: const Text('Text invite'),
        ),
      ],
    ),
  );
  if (send != true || !context.mounted) return;
  await sendGolferSmsInvite(auth, messenger,
      golfer: golfer, courseName: courseName);
}

/// Fetches the caller's personal invite link, builds a seeded invite message
/// (named to [golfer], and mentioning the round when [courseName] is given),
/// and opens Messages addressed to the golfer's phone with the body pre-filled.
/// The link still downloads the app + drives the phone-match connection; when
/// the golfer verifies this number they see the round in their Casual Rounds.
Future<void> sendGolferSmsInvite(
  AuthProvider auth,
  ScaffoldMessengerState messenger, {
  required PlayerProfile golfer,
  String? courseName,
}) async {
  final String url;
  try {
    url = (await auth.client.getInvite()).url;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not create your invite link: $e')),
    );
    return;
  }

  final first = golfer.name.trim().split(RegExp(r'\s+')).first;
  final hasCourse = courseName != null && courseName.trim().isNotEmpty;
  final body = hasCourse
      ? 'Hi $first! I added you to our round at ${courseName.trim()} on Halved '
          "— the easiest way to track our golf bets. Get the app and verify "
          "this number and you'll see our round: $url"
      : 'Hi $first! I use Halved to track our golf bets — the easiest way to '
          'settle up. Get the app and verify this number so we\'re connected: '
          '$url';

  final ok = await _launchSmsInvite(phone: golfer.phone, body: body);
  if (!ok) {
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't open Messages. Invite link: $url")),
    );
  }
}

/// Presents the native in-app message composer pre-addressed to [phone] with
/// [body] filled in. On iOS this is MFMessageComposeViewController — a sheet
/// shown OVER Halved; the user taps Send (or Cancel) themselves and is returned
/// to Halved automatically when the sheet dismisses (no app switch, no "Halved"
/// top-left back tap). The body is passed natively, so no URL-encoding hack is
/// needed. Returns false if the device can't send SMS (e.g. simulator, an iPad
/// without Messages) or the composer failed to open — callers then fall back to
/// surfacing the invite link.
Future<bool> _launchSmsInvite({
  required String phone,
  required String body,
}) async {
  final cleaned = phone.replaceAll(RegExp(r'[^0-9+]'), '');
  if (!await canSendSms()) return false;
  return sendSms(message: body, recipients: [cleaned]);
}
