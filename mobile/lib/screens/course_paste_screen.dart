/// screens/course_paste_screen.dart
/// --------------------------------
/// Hand-import a course (or re-rate an existing course's tees) by
/// pasting a scorecard.  See services/course_paste.py for the
/// expected format.
///
/// Two modes:
///   * `replaceCourseId == null` → create a brand-new course.  A
///     "Course name" field appears at top.
///   * `replaceCourseId != null` → update tees on an existing
///     course in place, preserving tee IDs so the re-rating doesn't
///     break any PROTECT FKs from played rounds.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

class CoursePasteScreen extends StatefulWidget {
  /// When set, the screen updates this course's tees rather than
  /// creating a new one.  The "Course name" field is hidden.
  final int?    replaceCourseId;
  final String? replaceCourseName;

  const CoursePasteScreen({
    super.key,
    this.replaceCourseId,
    this.replaceCourseName,
  });

  bool get isReplace => replaceCourseId != null;

  @override
  State<CoursePasteScreen> createState() => _CoursePasteScreenState();
}

class _CoursePasteScreenState extends State<CoursePasteScreen> {
  final _nameCtrl  = TextEditingController();
  final _pasteCtrl = TextEditingController();

  bool   _busy = false;
  String? _error;

  /// Last parsed dry-run result.  When set, the "Save" button is
  /// enabled and the preview pane shows what would be persisted.
  Map<String, dynamic>? _preview;

  static const _example = '''Tee specs (one per line):
  Black, 144, 75.5, M
  Blue,  138, 72.7, M
  White, 130, 70.1, M
  Red,   124, 70.7, W

Then a holes header + 18 rows:
  Hole Par SI Black Blue White Red
  1    4   7  412   395  365   315
  …
  18   4   4  450   430  405   355

Tabs, commas, or whitespace all work as separators.''';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pasteCtrl.dispose();
    super.dispose();
  }

  Future<void> _preflight() async {
    setState(() { _busy = true; _error = null; _preview = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final res = await client.pasteCourse(
        name:            widget.isReplace ? null : _nameCtrl.text.trim(),
        replaceCourseId: widget.replaceCourseId,
        paste:           _pasteCtrl.text,
        dryRun:          true,
      );
      if (mounted) setState(() { _preview = res; _busy = false; });
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

  Future<void> _commit() async {
    setState(() { _busy = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.pasteCourse(
        name:            widget.isReplace ? null : _nameCtrl.text.trim(),
        replaceCourseId: widget.replaceCourseId,
        paste:           _pasteCtrl.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(widget.isReplace
            ? 'Updated ${widget.replaceCourseName ?? "course"}.'
            : 'Imported ${_nameCtrl.text.trim()}.'),
      ));
      Navigator.of(context).pop(true);
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
    final canPreview =
        _pasteCtrl.text.trim().isNotEmpty &&
        (widget.isReplace || _nameCtrl.text.trim().isNotEmpty);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isReplace ? 'Re-rate Tees' : 'Paste Course'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.isReplace)
                Card(
                  elevation: 0,
                  color: theme.colorScheme.secondaryContainer
                      .withOpacity(0.4),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      const Icon(Icons.update, size: 18),
                      const SizedBox(width: 8),
                      Flexible(child: Text(
                        'Updating tees on ${widget.replaceCourseName ?? "this course"}.  '
                        'Existing tees with matching names will be '
                        'updated in place (so played rounds stay '
                        'intact).  Tees that aren\'t in your paste '
                        'are left alone.',
                        style: theme.textTheme.bodySmall,
                      )),
                    ]),
                  ),
                )
              else
                TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Course name',
                    border: OutlineInputBorder(),
                    helperText: 'Must be unique within this account.',
                  ),
                  onChanged: (_) {
                    setState(() { _preview = null; });
                  },
                ),
              const SizedBox(height: 16),

              TextField(
                controller: _pasteCtrl,
                maxLines: 18,
                minLines: 12,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'Scorecard paste',
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                  helperMaxLines: 12,
                  helperText: _example,
                ),
                onChanged: (_) {
                  // Invalidate any previous preview when the paste
                  // changes — user must hit Preview again.
                  if (_preview != null) {
                    setState(() { _preview = null; });
                  }
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
                      Expanded(child: Text(
                        _error!,
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
                _PreviewCard(preview: _preview!),
              ],

              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: OutlinedButton.icon(
                  onPressed: (_busy || !canPreview) ? null : _preflight,
                  icon: const Icon(Icons.preview_outlined),
                  label: const Text('Preview'),
                )),
                const SizedBox(width: 12),
                Expanded(child: FilledButton.icon(
                  onPressed: (_busy || _preview == null) ? null : _commit,
                  icon: _busy
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: Text(widget.isReplace ? 'Save Changes' : 'Create Course'),
                )),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline preview of the parsed payload.  Shows tee table + first /
/// last few holes so the user can sanity-check before committing.
class _PreviewCard extends StatelessWidget {
  final Map<String, dynamic> preview;
  const _PreviewCard({required this.preview});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tees  = (preview['tees']  as List? ?? []).cast<Map>();
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

            // Tees table
            Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              children: [
                const TableRow(children: [
                  _CellHead('Tee'),
                  _CellHead('Slope'),
                  _CellHead('Rating'),
                  _CellHead('Par'),
                  _CellHead('Sex'),
                ]),
                ...tees.map((t) => TableRow(children: [
                  _Cell(t['name'] as String),
                  _Cell('${t['slope']}'),
                  _Cell('${t['course_rating']}'),
                  _Cell('${t['par']}'),
                  _Cell(t['sex']?.toString() ?? '—'),
                ])),
              ],
            ),
            const SizedBox(height: 12),

            // Hole summary — just first 3 and last 3 to keep the
            // preview short.  The user has already pasted the data;
            // this is sanity-check, not duplicate display.
            Text(
              '${holes.length} hole rows parsed',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            if (holes.isNotEmpty) ...[
              for (final h in holes.take(3)) _holeLine(h, theme),
              if (holes.length > 6)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('…',
                      style: theme.textTheme.bodySmall),
                ),
              if (holes.length > 3)
                for (final h in holes.skip(holes.length - 3))
                  _holeLine(h, theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _holeLine(Map h, ThemeData theme) {
    final yards = (h['yards_by_tee'] as Map? ?? {});
    final yardStr = yards.entries
        .map((e) => '${e.key}=${e.value}').join('  ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text(
        '#${h['number']}  Par ${h['par']}  SI ${h['stroke_index']}  '
        '·  $yardStr',
        style: theme.textTheme.bodySmall
            ?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}

class _CellHead extends StatelessWidget {
  final String text;
  const _CellHead(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(text,
            style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}

class _Cell extends StatelessWidget {
  final String text;
  const _Cell(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(text),
      );
}
