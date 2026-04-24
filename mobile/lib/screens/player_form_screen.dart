/// screens/player_form_screen.dart
/// Add a new player or edit an existing one.
/// Returns true to the caller if a save was made.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

class PlayerFormScreen extends StatefulWidget {
  /// Pass null to create a new player, or a PlayerProfile to edit.
  final PlayerProfile? player;

  const PlayerFormScreen({super.key, this.player});

  @override
  State<PlayerFormScreen> createState() => _PlayerFormScreenState();
}

class _PlayerFormScreenState extends State<PlayerFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _shortCtrl;
  late final TextEditingController _hcpCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;
  late final TextEditingController _confirmCtrl;

  /// 'M' or 'W'.  Drives the default tee during round setup.  Defaults
  /// to 'M' for new players to match the server-side default.
  String _sex = 'M';

  /// True when the user has manually touched the short_name field.
  /// While this is false we keep the field auto-synced to the initials
  /// computed from the current Full Name input, so new players get a
  /// sensible default that updates as they type without ever overwriting
  /// a value the user typed on purpose.
  bool _shortNameUserEdited = false;

  bool _obscurePassword = true;
  bool _obscureConfirm  = true;

  bool    _saving = false;
  String? _error;

  bool get _isEdit => widget.player != null;

  @override
  void initState() {
    super.initState();
    final p = widget.player;
    _nameCtrl     = TextEditingController(text: p?.name ?? '');
    _shortCtrl    = TextEditingController(text: p?.shortName ?? '');
    _hcpCtrl      = TextEditingController(text: p?.handicapIndex ?? '');
    _emailCtrl    = TextEditingController(text: p?.email ?? '');
    _phoneCtrl    = TextEditingController(text: p?.phone ?? '');
    _usernameCtrl = TextEditingController();
    _passwordCtrl = TextEditingController();
    _confirmCtrl  = TextEditingController();
    _sex          = p?.sex ?? 'M';
    // Treat an existing non-empty short_name on an edit as "user-supplied"
    // so we don't stomp on it when the user edits the name field.  For
    // new players we start in auto-sync mode so typing the name fills
    // out the short label.
    _shortNameUserEdited = (p?.shortName.isNotEmpty ?? false);

    _nameCtrl.addListener(_maybeAutoFillShortName);
  }

  void _maybeAutoFillShortName() {
    if (_shortNameUserEdited) return;
    final next = PlayerProfile.computeInitials(_nameCtrl.text);
    if (_shortCtrl.text != next) {
      // Preserve cursor position implicitly — this field is tiny (≤5
      // chars) and almost always edited by retyping, so full replace is
      // fine.  Using setState is unnecessary since we're only updating
      // a controller, but the decoration's counter updates anyway via
      // the TextFormField's internal listener.
      _shortCtrl.text = next;
    }
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_maybeAutoFillShortName);
    _nameCtrl.dispose();
    _shortCtrl.dispose();
    _hcpCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _saving = true; _error = null; });

    try {
      final client = context.read<AuthProvider>().client;
      final name  = _nameCtrl.text.trim();
      // Preserve the user's case verbatim — they may have deliberately
      // typed mixed-case (e.g. "PaulL").  The auto-fill path in
      // _maybeAutoFillShortName() still produces uppercase initials for
      // the default value, so "JS" remains the out-of-the-box look.
      final shortName = _shortCtrl.text.trim();
      final hcp   = _hcpCtrl.text.trim();
      final email = _emailCtrl.text.trim();
      final phone = _phoneCtrl.text.trim();

      if (_isEdit) {
        await client.updatePlayer(
          widget.player!.id,
          name: name,
          // Always send short_name on edit: the server treats '' as
          // "clear and re-derive from initials", which matches the UX
          // of clearing the field in the form.
          shortName: shortName,
          handicapIndex: hcp,
          email: email,
          phone: phone,
          sex: _sex,
        );
      } else {
        final username = _usernameCtrl.text.trim();
        final password = _passwordCtrl.text;
        await client.createPlayer(
          name: name,
          // Only send when non-empty so the server's auto-fill on save()
          // kicks in for users who leave the field blank.
          shortName: shortName.isNotEmpty ? shortName : null,
          handicapIndex: hcp,
          email: email,
          phone: phone,
          sex: _sex,
          username: username.isNotEmpty ? username : null,
          password: password.isNotEmpty ? password : null,
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Player' : 'Add Player'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Name ----
              TextFormField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Full Name',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Name is required';
                  if (v.trim().length < 2) return 'Name too short';
                  return null;
                },
              ),

              const SizedBox(height: 16),

              // ---- Short name (≤ 5 chars) ----
              // Auto-syncs with Full Name while untouched; the moment the
              // user types or clears it manually we stop updating it
              // automatically so their chosen label isn't overwritten.
              // Case-preserving: mixed-case values like "PaulL" are kept
              // verbatim; the auto-fill path still produces uppercase
              // initials ("PL") by default, matching the legacy look.
              TextFormField(
                controller: _shortCtrl,
                maxLength: 5,
                onChanged: (_) => _shortNameUserEdited = true,
                decoration: const InputDecoration(
                  labelText: 'Short Name',
                  hintText: 'e.g. PL or PaulL',
                  prefixIcon: Icon(Icons.badge_outlined),
                  border: OutlineInputBorder(),
                  helperText: 'Up to 5 chars. Shown on compact screens '
                              '(Sixes teams, leaderboards). Leave blank '
                              'to auto-fill from initials.',
                ),
                validator: (v) {
                  // Optional — empty is fine (server re-derives).
                  if (v == null) return null;
                  if (v.length > 5) return 'Max 5 characters';
                  return null;
                },
              ),

              const SizedBox(height: 16),

              // ---- Handicap Index ----
              TextFormField(
                controller: _hcpCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(
                  labelText: 'Handicap Index',
                  hintText: 'e.g. 14.2',
                  prefixIcon: Icon(Icons.golf_course),
                  border: OutlineInputBorder(),
                  helperText: 'WHS index between -10.0 and 54.0',
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Handicap is required';
                  final d = double.tryParse(v.trim());
                  if (d == null) return 'Enter a valid number';
                  if (d < -10 || d > 54) return 'Must be between -10 and 54';
                  return null;
                },
              ),

              const SizedBox(height: 16),

              // ---- Sex (picks default tee during round setup) ----
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Tee designation',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.flag_outlined),
                  helperText: 'Used to pick the default tee at round setup.',
                ),
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'M', label: Text('Men')),
                    ButtonSegment(value: 'W', label: Text('Women')),
                  ],
                  selected: {_sex},
                  onSelectionChanged: (s) => setState(() => _sex = s.first),
                ),
              ),

              const SizedBox(height: 16),

              // ---- Email ----
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email (optional)',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null; // optional
                  final ok = RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(v.trim());
                  return ok ? null : 'Enter a valid email';
                },
              ),

              const SizedBox(height: 16),

              // ---- Phone ----
              TextFormField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                  prefixIcon: Icon(Icons.phone_outlined),
                  border: OutlineInputBorder(),
                ),
              ),

              // ---- Login credentials (new players only) ----
              if (!_isEdit) ...[
                const SizedBox(height: 28),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'App Login (optional)',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Create login credentials so this player can sign in to '
                  'record their own scores. Leave blank to skip.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),

                // Username
                TextFormField(
                  controller: _usernameCtrl,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    hintText: 'e.g. jsmith',
                    prefixIcon: Icon(Icons.account_circle_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final u = v?.trim() ?? '';
                    final p = _passwordCtrl.text;
                    if (u.isEmpty && p.isEmpty) return null; // both blank = skip
                    if (u.isEmpty) return 'Enter a username';
                    if (u.length < 3) return 'At least 3 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Password
                TextFormField(
                  controller: _passwordCtrl,
                  obscureText: _obscurePassword,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (v) {
                    final u = _usernameCtrl.text.trim();
                    final p = v ?? '';
                    if (u.isEmpty && p.isEmpty) return null;
                    if (p.isEmpty) return 'Enter a password';
                    if (p.length < 6) return 'At least 6 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Confirm password
                TextFormField(
                  controller: _confirmCtrl,
                  obscureText: _obscureConfirm,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Confirm Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureConfirm
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                  validator: (v) {
                    final u = _usernameCtrl.text.trim();
                    final p = _passwordCtrl.text;
                    if (u.isEmpty && p.isEmpty) return null;
                    if ((v ?? '') != p) return 'Passwords do not match';
                    return null;
                  },
                ),
              ],

              const SizedBox(height: 28),

              // ---- Error ----
              if (_error != null) ...[
                ErrorView(message: _error!),
                const SizedBox(height: 16),
              ],

              // ---- Save ----
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check),
                label: Text(_saving
                    ? 'Saving…'
                    : _isEdit ? 'Save Changes' : 'Add Player'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
