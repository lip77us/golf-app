/// screens/profile_setup_screen.dart
/// First-run setup shown only to brand-new accounts (created via phone
/// sign-up).  Lets the new user confirm their name, set a handicap index, and
/// pick their default tee sex, then drops them on the tournaments list.  All
/// fields have sensible defaults from sign-up, so "Skip for now" is allowed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/golf_primary_button.dart';
import '../widgets/golf_text_field.dart';

class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey  = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _shortCtrl;
  late final TextEditingController _hcpCtrl;
  String  _sex     = 'M';
  bool    _saving  = false;
  String? _error;

  /// While false, the short name auto-tracks the initials of the name field.
  /// A brand-new account starts with an auto-derived short ("NG" for the
  /// "New Golfer" default), so we begin in auto-sync mode — changing the name
  /// to the real one updates the short too. Editing the short field manually
  /// stops the auto-sync so the user's choice isn't overwritten.
  bool _shortNameUserEdited = false;

  @override
  void initState() {
    super.initState();
    final player = context.read<AuthProvider>().player;
    // Don't pre-fill the "New Golfer" placeholder the backend assigns when a
    // user signs up without a name — start empty so they enter their real one
    // (and the short name auto-fills from it).
    final rawName  = player?.name ?? '';
    final isDefault = rawName == 'New Golfer';
    _nameCtrl  = TextEditingController(text: isDefault ? '' : rawName);
    _shortCtrl = TextEditingController(
        text: isDefault ? '' : (player?.shortName ?? ''));
    _hcpCtrl   = TextEditingController(
      text: (player != null && player.handicapIndex.isNotEmpty)
          ? player.handicapIndex
          : '',
    );
    _sex = player?.sex ?? 'M';
    _nameCtrl.addListener(_maybeAutoFillShortName);
  }

  void _maybeAutoFillShortName() {
    if (_shortNameUserEdited) return;
    final next = PlayerProfile.computeInitials(_nameCtrl.text);
    if (_shortCtrl.text != next) _shortCtrl.text = next;
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_maybeAutoFillShortName);
    _nameCtrl.dispose();
    _shortCtrl.dispose();
    _hcpCtrl.dispose();
    super.dispose();
  }

  void _goToApp() {
    final nav = Navigator.of(context);
    // Home goes to the bottom of the stack; brand-new accounts then land in the
    // guided first-round wizard on top of it (so Skip / finishing a round pops
    // back to a real list rather than an empty stack).
    nav.pushNamedAndRemoveUntil('/tournaments', (_) => false);
    if (context.read<AuthProvider>().isNewAccount) {
      nav.pushNamed('/onboarding');
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final auth   = context.read<AuthProvider>();
    final player = auth.player;
    if (player == null) {
      _goToApp();
      return;
    }
    setState(() {
      _saving = true;
      _error  = null;
    });
    try {
      final updated = await auth.client.updatePlayer(
        player.id,
        name: _nameCtrl.text.trim(),
        // Always send short_name: a non-empty value is used as-is; '' tells the
        // server to re-derive it from the (new) name, so the stale "NG" default
        // can't linger after the name is set.
        shortName: _shortCtrl.text.trim(),
        handicapIndex: _hcpCtrl.text.trim().isEmpty
            ? '0.0'
            : _hcpCtrl.text.trim(),
        sex: _sex,
      );
      auth.applyPlayer(updated);
      if (mounted) _goToApp();
    } catch (e) {
      setState(() => _error = 'Could not save. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your profile'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _saving ? null : _goToApp,
            child: const Text('Skip'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Welcome! Tell us a bit about you.',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),

                GolfTextField(
                  controller: _nameCtrl,
                  label: 'Full name',
                  textCapitalization: TextCapitalization.words,
                  prefixIcon: Icons.person_outline,
                  textInputAction: TextInputAction.next,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),

                GolfTextField(
                  controller: _shortCtrl,
                  label: 'Short name',
                  hint: 'e.g. TS',
                  helper: 'Up to 5 chars, shown on compact scoreboards. '
                          'Auto-fills from your name.',
                  prefixIcon: Icons.badge_outlined,
                  maxLength: 5,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => _shortNameUserEdited = true,
                ),
                const SizedBox(height: 16),

                GolfTextField(
                  controller: _hcpCtrl,
                  label: 'Handicap index',
                  hint: 'e.g. 14.2',
                  helper: 'Leave blank if you don\'t know it yet',
                  prefixIcon: Icons.sports_golf_outlined,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                  ],
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return null;
                    final n = double.tryParse(t);
                    if (n == null) return 'Enter a number';
                    if (n < -10 || n > 54) return 'Must be between -10 and 54';
                    return null;
                  },
                ),
                const SizedBox(height: 20),

                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Default tees',
                      style: theme.textTheme.labelLarge),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'M', label: Text("Men's")),
                    ButtonSegment(value: 'W', label: Text("Women's")),
                  ],
                  selected: {_sex},
                  onSelectionChanged: (s) =>
                      setState(() => _sex = s.first),
                ),

                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 28),

                GolfPrimaryButton(
                  label: 'Continue',
                  loading: _saving,
                  onPressed: _save,
                  height: 48,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
