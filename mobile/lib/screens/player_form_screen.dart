/// screens/player_form_screen.dart
/// Add a new player or edit an existing one.
/// Returns true to the caller if a save was made.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';

class PlayerFormScreen extends StatefulWidget {
  /// Pass null to create a new player, or a PlayerProfile to edit.
  final PlayerProfile? player;

  /// Read-only mode for non-admins: fields are shown but not editable
  /// and the Save button is hidden.  Creating/editing players is
  /// admin-only (the backend enforces this too), so non-admins reach
  /// this screen only to view a player's details.
  final bool readOnly;

  const PlayerFormScreen({super.key, this.player, this.readOnly = false});

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

  /// 'M' or 'W'.  Drives the default tee during round setup.  Defaults
  /// to 'M' for new players to match the server-side default.
  String _sex = 'M';

  /// True when the user has manually touched the short_name field.
  /// While this is false we keep the field auto-synced to the initials
  /// computed from the current Full Name input, so new players get a
  /// sensible default that updates as they type without ever overwriting
  /// a value the user typed on purpose.
  bool _shortNameUserEdited = false;

  bool    _saving = false;
  String? _error;

  bool get _isEdit => widget.player != null;

  @override
  void initState() {
    super.initState();
    final p = widget.player;
    _nameCtrl     = TextEditingController(text: p?.name ?? '');
    _shortCtrl    = TextEditingController(text: p?.shortName ?? '');
    _hcpCtrl      = TextEditingController(text: p?.displayHandicap ?? '');
    _emailCtrl    = TextEditingController(text: p?.email ?? '');
    _phoneCtrl    = TextEditingController(text: p?.phone ?? '');
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

      final PlayerProfile saved;
      if (_isEdit) {
        saved = await client.updatePlayer(
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
        saved = await client.createPlayer(
          name: name,
          // Only send when non-empty so the server's auto-fill on save()
          // kicks in for users who leave the field blank.
          shortName: shortName.isNotEmpty ? shortName : null,
          handicapIndex: hcp,
          email: email,
          phone: phone,
          sex: _sex,
        );
      }

      // Pop with the saved PlayerProfile so callers (e.g. the inline
      // "Add a golfer" flow in round setup) can select it immediately.
      // Existing callers just null-check the result, so this stays
      // backward-compatible.
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.readOnly
            ? 'Player Details'
            : _isEdit ? 'Edit Player' : 'Add Player'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Opacity(
          opacity: widget.readOnly ? 0.7 : 1.0,
          child: AbsorbPointer(
            absorbing: widget.readOnly,
            child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Name ----
              GolfTextField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                label: 'Full Name',
                prefixIcon: Icons.person_outline,
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
              GolfTextField(
                controller: _shortCtrl,
                maxLength: 5,
                onChanged: (_) => _shortNameUserEdited = true,
                label: 'Short Name',
                hint: 'e.g. PL or PaulL',
                prefixIcon: Icons.badge_outlined,
                helper: 'Up to 5 chars. Shown on compact screens '
                        '(Sixes teams, leaderboards). Leave blank '
                        'to auto-fill from initials.',
                validator: (v) {
                  // Optional — empty is fine (server re-derives).
                  if (v == null) return null;
                  if (v.length > 5) return 'Max 5 characters';
                  return null;
                },
              ),

              const SizedBox(height: 16),

              // ---- Handicap Index ----
              GolfTextField(
                controller: _hcpCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                label: 'Handicap Index',
                hint: 'e.g. 14.2',
                prefixIcon: Icons.golf_course,
                helper: 'WHS index between -10.0 and 54.0',
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

              // ---- Phone ----
              // Above email on purpose: the phone number is how a golfer links
              // across accounts (auto-connect on signup, "On Halved", round
              // sharing, the texted invite).
              GolfTextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                label: 'Phone (optional)',
                prefixIcon: Icons.phone_outlined,
                helper: 'When this golfer joins Halved with this number, '
                        'they automatically connect to this profile.',
              ),

              const SizedBox(height: 16),

              // ---- Email ----
              GolfTextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                label: 'Email (optional)',
                prefixIcon: Icons.email_outlined,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null; // optional
                  final ok = RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(v.trim());
                  return ok ? null : 'Enter a valid email';
                },
              ),

              const SizedBox(height: 28),

              // ---- Error ----
              if (_error != null) ...[
                ErrorView(message: _error!),
                const SizedBox(height: 16),
              ],

              // ---- Save ----
              if (!widget.readOnly)
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
        ),
      ),
    );
  }
}
