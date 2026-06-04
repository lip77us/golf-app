/// screens/profile_setup_screen.dart
/// First-run setup shown only to brand-new accounts (created via phone
/// sign-up).  Lets the new user confirm their name, set a handicap index, and
/// pick their default tee sex, then drops them on the tournaments list.  All
/// fields have sensible defaults from sign-up, so "Skip for now" is allowed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
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
  late final TextEditingController _hcpCtrl;
  String  _sex     = 'M';
  bool    _saving  = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final player = context.read<AuthProvider>().player;
    _nameCtrl = TextEditingController(text: player?.name ?? '');
    _hcpCtrl  = TextEditingController(
      text: (player != null && player.handicapIndex.isNotEmpty)
          ? player.handicapIndex
          : '',
    );
    _sex = player?.sex ?? 'M';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hcpCtrl.dispose();
    super.dispose();
  }

  void _goToApp() {
    Navigator.of(context)
        .pushNamedAndRemoveUntil('/tournaments', (_) => false);
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
                  prefixIcon: Icons.person_outline,
                  textInputAction: TextInputAction.next,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
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
