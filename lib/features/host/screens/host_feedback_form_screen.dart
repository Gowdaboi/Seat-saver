import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

/// Real feedback form editor: one feedback_forms row per event, holding an
/// ordered list of question texts in questions_json. "Simple" per
/// project-spec.md — open-ended text questions, no question types/scoring,
/// and this screen only edits the form itself, not response results (v2+
/// territory per the spec's "rich analytics/reporting" deferral).
class HostFeedbackFormScreen extends StatefulWidget {
  const HostFeedbackFormScreen({super.key});

  @override
  State<HostFeedbackFormScreen> createState() => _HostFeedbackFormScreenState();
}

class _HostFeedbackFormScreenState extends State<HostFeedbackFormScreen> {
  String? _eventId;
  final _contentKey = GlobalKey<_FeedbackContentState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feedback form'),
        actions: [
          if (_eventId != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _contentKey.currentState?.reload(),
            ),
        ],
      ),
      body: EventPicker(
        onEventChanged: (id) => setState(() => _eventId = id),
        builder: (context, eventId) => _FeedbackContent(key: _contentKey, eventId: eventId),
      ),
    );
  }
}

class _FeedbackContent extends StatefulWidget {
  const _FeedbackContent({super.key, required this.eventId});
  final String eventId;

  @override
  State<_FeedbackContent> createState() => _FeedbackContentState();
}

class _FeedbackContentState extends State<_FeedbackContent> {
  String? _formId;
  List<TextEditingController>? _questionControllers;
  String? _error;
  bool _loaded = false;
  bool _mutating = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(covariant _FeedbackContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      _disposeControllers();
      _formId = null;
      _questionControllers = null;
      _loaded = false;
      reload();
    }
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  void _disposeControllers() {
    for (final c in _questionControllers ?? const <TextEditingController>[]) {
      c.dispose();
    }
  }

  Future<void> reload() async {
    setState(() => _error = null);
    try {
      final row = await supabase
          .from('feedback_forms')
          .select('id, questions_json')
          .eq('event_id', widget.eventId)
          .maybeSingle();
      _disposeControllers();
      if (row == null) {
        setState(() {
          _formId = null;
          _questionControllers = null;
          _loaded = true;
        });
      } else {
        final questions = List<dynamic>.from(row['questions_json'] as List).cast<String>();
        setState(() {
          _formId = row['id'] as String;
          _questionControllers = [for (final q in questions) TextEditingController(text: q)];
          _dirty = false;
          _loaded = true;
        });
      }
    } catch (e) {
      setState(() => _error = 'Could not load feedback form: $e');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _createForm() async {
    setState(() => _mutating = true);
    try {
      await supabase.from('feedback_forms').insert({
        'event_id': widget.eventId,
        'questions_json': <String>[],
      });
      await reload();
    } catch (e) {
      _showError('Could not create feedback form: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  void _addQuestion() {
    setState(() {
      _questionControllers!.add(TextEditingController());
      _dirty = true;
    });
  }

  void _removeQuestion(int index) {
    setState(() {
      _questionControllers!.removeAt(index).dispose();
      _dirty = true;
    });
  }

  Future<void> _save() async {
    setState(() => _mutating = true);
    try {
      final questions = _questionControllers!
          .map((c) => c.text.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      await supabase.from('feedback_forms').update({'questions_json': questions}).eq('id', _formId!);
      await reload();
      _showError('Saved.');
    } catch (e) {
      _showError('Could not save: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_formId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('No feedback form for this event yet.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _mutating ? null : _createForm,
                child: const Text('Create feedback form'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _questionControllers!.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _questionControllers![i],
                      decoration: InputDecoration(labelText: 'Question ${i + 1}'),
                      onChanged: (_) => setState(() => _dirty = true),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _removeQuestion(i),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _addQuestion,
                  icon: const Icon(Icons.add),
                  label: const Text('Add question'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _mutating || !_dirty ? null : _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
