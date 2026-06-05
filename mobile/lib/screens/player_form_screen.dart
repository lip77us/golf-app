/// screens/player_form_screen.dart
/// Add a new player or edit an existing one.
/// Returns true to the caller if a save was made.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/inline_message.dart';

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

  /// Available account members for the "Linked App User" picker.
  /// Loaded once on mount.  We include the currently-linked member
  /// (if any) so the dropdown can show their name even when the
  /// rest of the list filters to unlinked members.
  List<Member>? _members;
  bool          _membersLoaded   = false;
  String?       _membersError;

  /// Currently selected member id (null = "no linked login").
  int? _linkedUserId;

  /// On the new-player form the admin chooses one of:
  ///   * 'none'      — no linked login
  ///   * 'existing'  — link to a member created via Manage Members
  ///   * 'new'       — create a new login (username + password below)
  /// Defaults to 'none' so the form looks clean on first load.
  String _newLoginMode = 'none';

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
    _linkedUserId = p?.userId;

    _nameCtrl.addListener(_maybeAutoFillShortName);
    // Members list is only useful to admins (they're the only ones
    // who can manage links).  Non-admins won't see the picker UI, so
    // we skip the fetch entirely for them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadMembersIfAdmin();
    });
  }

  Future<void> _loadMembersIfAdmin() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isAdmin) {
      setState(() { _membersLoaded = true; });
      return;
    }
    try {
      final list = await auth.client.getAccountMembers();
      if (mounted) setState(() {
        _members       = list;
        _membersLoaded = true;
      });
    } catch (e) {
      if (mounted) setState(() {
        _membersError  = friendlyError(e);
        _membersLoaded = true;
      });
    }
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

      final PlayerProfile saved;
      if (_isEdit) {
        // Only rebind the link if it actually changed — pass through
        // explicitly so the server can distinguish "unlink" from
        // "leave alone".
        final originalUserId = widget.player!.userId;
        final linkChanged    = _linkedUserId != originalUserId;
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
          userId:     linkChanged ? _linkedUserId : null,
          unlinkUser: linkChanged && _linkedUserId == null,
        );
      } else {
        final username = _usernameCtrl.text.trim();
        final password = _passwordCtrl.text;
        saved = await client.createPlayer(
          name: name,
          // Only send when non-empty so the server's auto-fill on save()
          // kicks in for users who leave the field blank.
          shortName: shortName.isNotEmpty ? shortName : null,
          handicapIndex: hcp,
          email: email,
          phone: phone,
          sex: _sex,
          userId:   _newLoginMode == 'existing' ? _linkedUserId : null,
          username: _newLoginMode == 'new' && username.isNotEmpty
                      ? username : null,
          password: _newLoginMode == 'new' && password.isNotEmpty
                      ? password : null,
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

              const SizedBox(height: 16),

              // ---- Phone ----
              GolfTextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                label: 'Phone (optional)',
                prefixIcon: Icons.phone_outlined,
              ),

              // ---- App-login section ----
              // Admins only.  Non-admin members shouldn't see member
              // management surfaces, mirroring the drawer's gating.
              if (context.read<AuthProvider>().isAdmin) ...[
                const SizedBox(height: 28),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'App Login',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  _isEdit
                      ? 'Link this player to an account member so they '
                        'can sign in and enter their own scores.'
                      : 'Optional.  Either link an existing member or '
                        'create a brand-new login for this player.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                if (!_membersLoaded)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_membersError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: InlineMessage(
                        kind: InlineMessageKind.error,
                        text: _membersError!),
                  )
                else if (_isEdit)
                  // Single dropdown for edit mode: "no link" plus every
                  // existing member.  Showing currently-linked members
                  // (the one for this player + nobody else) avoids
                  // accidentally hiding the active selection.
                  _LinkedMemberPicker(
                    members:        _members ?? const [],
                    selectedId:     _linkedUserId,
                    currentPlayerId: widget.player?.id,
                    onChanged:      (id) =>
                        setState(() => _linkedUserId = id),
                  )
                else ...[
                  // Add mode: pick one of three branches.  Labels are
                  // one short word each because the three-segment row
                  // is tight on narrow phones — the helper text above
                  // ("Either link an existing member or create a
                  // brand-new login") carries the longer description.
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'none',
                        label: Text('None'),
                        icon: Icon(Icons.person_off_outlined),
                      ),
                      ButtonSegment(
                        value: 'existing',
                        label: Text('Existing'),
                        icon: Icon(Icons.link),
                      ),
                      ButtonSegment(
                        value: 'new',
                        label: Text('New'),
                        icon: Icon(Icons.person_add_alt_1),
                      ),
                    ],
                    selected: {_newLoginMode},
                    onSelectionChanged: (s) => setState(() {
                      _newLoginMode = s.first;
                      if (_newLoginMode != 'existing') _linkedUserId = null;
                    }),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_newLoginMode == 'existing')
                    _LinkedMemberPicker(
                      members:        _members ?? const [],
                      selectedId:     _linkedUserId,
                      currentPlayerId: null,
                      onChanged:      (id) =>
                          setState(() => _linkedUserId = id),
                    ),
                  if (_newLoginMode == 'new') ...[
                    // Username
                    GolfTextField(
                      controller: _usernameCtrl,
                      autocorrect: false,
                      enableSuggestions: false,
                      label: 'Username',
                      hint: 'e.g. jsmith',
                      prefixIcon: Icons.account_circle_outlined,
                      validator: (v) {
                        if (_newLoginMode != 'new') return null;
                        final u = v?.trim() ?? '';
                        if (u.isEmpty) return 'Enter a username';
                        if (u.length < 3) return 'At least 3 characters';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    // Password
                    GolfTextField(
                      controller: _passwordCtrl,
                      obscureText: _obscurePassword,
                      enableSuggestions: false,
                      autocorrect: false,
                      label: 'Password',
                      prefixIcon: Icons.lock_outline,
                      suffix: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                      validator: (v) {
                        if (_newLoginMode != 'new') return null;
                        final p = v ?? '';
                        if (p.isEmpty) return 'Enter a password';
                        if (p.length < 6) return 'At least 6 characters';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    // Confirm password
                    GolfTextField(
                      controller: _confirmCtrl,
                      obscureText: _obscureConfirm,
                      enableSuggestions: false,
                      autocorrect: false,
                      label: 'Confirm Password',
                      prefixIcon: Icons.lock_outline,
                      suffix: IconButton(
                        icon: Icon(_obscureConfirm
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () => setState(
                            () => _obscureConfirm = !_obscureConfirm),
                      ),
                      validator: (v) {
                        if (_newLoginMode != 'new') return null;
                        if ((v ?? '') != _passwordCtrl.text) {
                          return 'Passwords do not match';
                        }
                        return null;
                      },
                    ),
                  ],
                ],
              ],

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

/// Dropdown of account members for the "Linked App User" picker.
/// Shows every member, with already-linked ones disabled — except
/// the one currently linked to THIS player (which stays selectable
/// so the admin can keep it).
class _LinkedMemberPicker extends StatelessWidget {
  final List<Member>     members;
  final int?             selectedId;
  /// Player id being edited.  Used to recognise "this player's own
  /// linked member" and keep them selectable.  Null in add mode.
  final int?             currentPlayerId;
  final ValueChanged<int?> onChanged;

  const _LinkedMemberPicker({
    required this.members,
    required this.selectedId,
    required this.currentPlayerId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Sort: admins first, then alphabetical — matches Manage Members.
    final sorted = [...members]..sort((a, b) {
      if (a.isAccountAdmin != b.isAccountAdmin) {
        return a.isAccountAdmin ? -1 : 1;
      }
      return a.username.toLowerCase().compareTo(b.username.toLowerCase());
    });

    return DropdownButtonFormField<int?>(
      value: selectedId,
      decoration: const InputDecoration(
        labelText: 'Linked App User',
        prefixIcon: Icon(Icons.link),
        border: OutlineInputBorder(),
        helperText: 'Members already linked to another player are '
                    'disabled.',
      ),
      isExpanded: true,
      items: [
        const DropdownMenuItem<int?>(
          value: null,
          child: Text('— None —'),
        ),
        ...sorted.map((m) {
          // Already linked to a DIFFERENT player → disabled.  Linked
          // to no one OR linked to this player → enabled.
          final linkedElsewhere = m.hasPlayerProfile && m.id != selectedId;
          return DropdownMenuItem<int?>(
            value: m.id,
            enabled: !linkedElsewhere,
            child: Row(children: [
              Icon(m.isAccountAdmin
                      ? Icons.shield_outlined
                      : Icons.person_outline,
                  size: 16,
                  color: linkedElsewhere
                      ? theme.colorScheme.onSurfaceVariant.withOpacity(0.5)
                      : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(child: Text(
                m.displayName + (m.username != m.displayName
                                  ? '  (@${m.username})' : ''),
                overflow: TextOverflow.ellipsis,
                style: linkedElsewhere
                    ? TextStyle(color: theme.disabledColor)
                    : null,
              )),
              if (linkedElsewhere)
                Text('linked',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.disabledColor)),
            ]),
          );
        }),
      ],
      onChanged: onChanged,
    );
  }
}
