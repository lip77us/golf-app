/// screens/tee_paste_screen.dart
/// -----------------------------
/// Add a single tee to an existing course, or edit an existing one.
///
/// Designed for the cases the multi-tee CoursePasteScreen can't
/// handle:
///   * combo tees the GolfCourseAPI catalogue doesn't know about
///   * men's vs women's stroke indexes on the same course (each
///     tee carries its own SI per hole)
///   * re-rating one specific tee after USGA without touching the
///     others
///
/// Layout:
///   * Tee metadata at top: name + slope + course-rating + sex
///   * Paste textarea: 18 lines of "<hole> <par> <si> <yards>"
///     (header row optional)
///   * Preview → Save flow, same as CoursePasteScreen

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/error_view.dart';

class TeePasteScreen extends StatefulWidget {
  final int    courseId;
  final String courseName;
  /// If supplied, the screen pre-fills metadata + holes from this
  /// tee and posts an UPDATE on save.  Server keys on tee_name
  /// regardless, so passing this in is purely a convenience for
  /// the user (no need to retype name / slope / rating).
  final TeeInfo? existingTee;

  const TeePasteScreen({
    super.key,
    required this.courseId,
    required this.courseName,
    this.existingTee,
  });

  bool get isEdit => existingTee != null;

  @override
  State<TeePasteScreen> createState() => _TeePasteScreenState();
}

class _TeePasteScreenState extends State<TeePasteScreen> {
  final _nameCtrl   = TextEditingController();
  final _slopeCtrl  = TextEditingController();
  final _ratingCtrl = TextEditingController();
  final _pasteCtrl  = TextEditingController();

  String _sex   = 'M';
  bool   _busy  = false;
  String? _error;
  Map<String, dynamic>? _preview;

  static const _example = '''Optional header row:
  Hole Par SI Yards

Then 18 hole rows (whitespace, tabs, or commas):
  1    4   7   365
  2    5   3   490
  …
  18   4   4   405''';

  @override
  void initState() {
    super.initState();
    final t = widget.existingTee;
    if (t != null) {
      _nameCtrl.text   = t.teeName;
      _slopeCtrl.text  = t.slope.toString();
      _ratingCtrl.text = t.courseRating.toStringAsFixed(1);
      _sex = t.sex ?? 'U';
      // Pre-fill paste textarea with the current hole data so the
      // user can tweak just the rows that changed.
      if (t.holes.isNotEmpty) {
        final buf = StringBuffer();
        for (final h in t.holes) {
          buf.writeln('${h['number']}\t${h['par']}\t'
                      '${h['stroke_index']}\t${h['yards']}');
        }
        _pasteCtrl.text = buf.toString().trimRight();
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _slopeCtrl.dispose();
    _ratingCtrl.dispose();
    _pasteCtrl.dispose();
    super.dispose();
  }

  bool get _canPreview =>
      _nameCtrl.text.trim().isNotEmpty &&
      int.tryParse(_slopeCtrl.text.trim()) != null &&
      double.tryParse(_ratingCtrl.text.trim()) != null &&
      _pasteCtrl.text.trim().isNotEmpty;

  Future<void> _go({required bool dryRun}) async {
    setState(() {
      _busy = true;
      _error = null;
      if (dryRun) _preview = null;
    });
    try {
      final client = context.read<AuthProvider>().client;
      final res = await client.pasteTee(
        courseId:     widget.courseId,
        name:         _nameCtrl.text.trim(),
        slope:        int.parse(_slopeCtrl.text.trim()),
        courseRating: double.parse(_ratingCtrl.text.trim()),
        sex:          _sex == 'U' ? null : _sex,
        paste:        _pasteCtrl.text,
        dryRun:       dryRun,
      );
      if (!mounted) return;
      if (dryRun) {
        setState(() { _preview = res; _busy = false; });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.isEdit
              ? 'Updated ${_nameCtrl.text.trim()} tees.'
              : 'Added ${_nameCtrl.text.trim()} tees.'),
        ));
        Navigator.of(context).pop(true);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() {
        _error = e.message;
        _busy  = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = friendlyError(e);
        _busy  = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEdit ? 'Edit Tee' : 'Add Tee'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.courseName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
              const SizedBox(height: 12),

              // Tee metadata row 1: name (full width).
              GolfTextField(
                controller: _nameCtrl,
                label: 'Tee name',
                helper: 'e.g. "White", "Black/White Combo", "Gold M".',
                textCapitalization: TextCapitalization.words,
                onChanged: (_) {
                  if (_preview != null) setState(() { _preview = null; });
                },
              ),
              const SizedBox(height: 12),

              // Metadata row 2: slope + rating side by side.
              Row(children: [
                Expanded(child: GolfTextField(
                  controller: _slopeCtrl,
                  keyboardType: TextInputType.number,
                  label: 'Slope',
                  helper: '55–155',
                  onChanged: (_) {
                    if (_preview != null) setState(() { _preview = null; });
                  },
                )),
                const SizedBox(width: 12),
                Expanded(child: GolfTextField(
                  controller: _ratingCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  label: 'Course rating',
                  helper: '60.0–80.0',
                  onChanged: (_) {
                    if (_preview != null) setState(() { _preview = null; });
                  },
                )),
              ]),
              const SizedBox(height: 12),

              // Sex selector — drives the default-tee picker at
              // round setup.  Unisex tees show up for both M and W.
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'M', label: Text("Men")),
                  ButtonSegment(value: 'W', label: Text("Women")),
                  ButtonSegment(value: 'U', label: Text('Unisex')),
                ],
                selected: {_sex},
                onSelectionChanged: (s) => setState(() {
                  _sex = s.first;
                  _preview = null;
                }),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(height: 16),

              // Per-hole paste.
              TextField(
                controller: _pasteCtrl,
                maxLines: 20,
                minLines: 12,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Hole rows',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                  helperMaxLines: 6,
                  helperText: _example,
                ),
                onChanged: (_) {
                  if (_preview != null) setState(() { _preview = null; });
                },
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('Paste from clipboard'),
                  onPressed: () async {
                    final data =
                        await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null && mounted) {
                      _pasteCtrl.text = data!.text!;
                      setState(() { _preview = null; });
                    }
                  },
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      )),
                    ],
                  ),
                ),
              ],

              if (_preview != null) ...[
                const SizedBox(height: 16),
                _TeePreviewCard(preview: _preview!),
              ],

              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: OutlinedButton.icon(
                  onPressed: (_busy || !_canPreview)
                      ? null : () => _go(dryRun: true),
                  icon: const Icon(Icons.preview_outlined),
                  label: const Text('Preview'),
                )),
                const SizedBox(width: 12),
                Expanded(child: FilledButton.icon(
                  onPressed: (_busy || _preview == null)
                      ? null : () => _go(dryRun: false),
                  icon: _busy
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: Text(widget.isEdit ? 'Save Changes' : 'Add Tee'),
                )),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _TeePreviewCard extends StatelessWidget {
  final Map<String, dynamic> preview;
  const _TeePreviewCard({required this.preview});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tee   = (preview['tee']   as Map?)   ?? {};
    final holes = (preview['holes'] as List? ?? []).cast<Map>();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Preview', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '${tee['name']}  ·  Slope ${tee['slope']}  ·  '
              'Rating ${tee['course_rating']}  ·  Par ${tee['par']}  ·  '
              '${tee['sex'] ?? 'Unisex'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text('${holes.length} hole rows parsed:',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            if (holes.isNotEmpty) ...[
              for (final h in holes.take(3))
                _line(h, theme),
              if (holes.length > 6)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('…', style: theme.textTheme.bodySmall),
                ),
              if (holes.length > 3)
                for (final h in holes.skip(holes.length - 3))
                  _line(h, theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _line(Map h, ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Text(
          '#${h['number']}  Par ${h['par']}  SI ${h['stroke_index']}'
          '  ·  ${h['yards']} yds',
          style: theme.textTheme.bodySmall
              ?.copyWith(fontFamily: 'monospace'),
        ),
      );
}
