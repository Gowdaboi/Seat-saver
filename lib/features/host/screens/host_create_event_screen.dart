import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_client.dart';

/// Real insert into events (see supabase/migrations/0001_init.sql) — the
/// rest of the host flow (floor design, menu, rounds...) is still
/// placeholder UI, so this doesn't yet chain into an event-scoped flow.
class HostCreateEventScreen extends StatefulWidget {
  const HostCreateEventScreen({super.key});

  @override
  State<HostCreateEventScreen> createState() => _HostCreateEventScreenState();
}

class _HostCreateEventScreenState extends State<HostCreateEventScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _venueController = TextEditingController();
  final _dateController = TextEditingController();
  final _noShowController = TextEditingController(text: '5');
  final _reassignController = TextEditingController(text: '1');
  String _serviceType = 'pankti';
  bool _submitting = false;
  String? _error;
  DateTime? _date;

  @override
  void dispose() {
    _nameController.dispose();
    _venueController.dispose();
    _dateController.dispose();
    _noShowController.dispose();
    _reassignController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
      initialDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _dateController.text = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      });
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _date == null) {
      setState(() => _error = _date == null ? 'Pick a date' : null);
      return;
    }
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _error = 'Not logged in');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Grabbed before the pop below, because after it this screen's context is
    // gone but the app-level messenger is still there to show the snackbar.
    final messenger = ScaffoldMessenger.of(context);
    final name = _nameController.text.trim();
    try {
      final caterer = await supabase
          .from('caterers')
          .select('id')
          .eq('auth_user_id', userId)
          .single();
      await supabase.from('events').insert({
        'caterer_id': caterer['id'],
        'name': name,
        'venue_name': _venueController.text.trim(),
        'date': _dateController.text,
        'service_type': _serviceType,
        'no_show_timeout_minutes': int.parse(_noShowController.text),
        'reassignment_response_minutes': int.parse(_reassignController.text),
      });
      if (mounted) {
        context.pop();
        // Creating an event used to return to the dashboard in silence, which
        // left the host unsure whether it had saved at all.
        messenger.showSnackBar(SnackBar(content: Text('Created "$name"')));
      }
    } on PostgrestException catch (e) {
      // 23505 here can only be events_caterer_name_uidx (0016): one caterer,
      // one event name. Reported in the host's own words rather than as a
      // constraint violation, since the fix is simply a different name.
      setState(() => _error = e.code == '23505'
          ? 'You already have an event called "$name". '
              'Give this one a different name so you can tell them apart.'
          : 'Could not create event: ${e.message}');
    } catch (e) {
      setState(() => _error = 'Could not create event: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create event')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Event name'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _venueController,
                    decoration: const InputDecoration(labelText: 'Venue name'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _dateController,
                    readOnly: true,
                    decoration: const InputDecoration(labelText: 'Date', suffixIcon: Icon(Icons.calendar_today)),
                    onTap: _pickDate,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _serviceType,
                    decoration: const InputDecoration(labelText: 'Service type'),
                    items: const [
                      DropdownMenuItem(value: 'pankti', child: Text('Pankti')),
                      DropdownMenuItem(value: 'buffet', child: Text('Buffet')),
                    ],
                    onChanged: (v) => setState(() => _serviceType = v!),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _noShowController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'No-show timeout (min)'),
                          validator: (v) => int.tryParse(v ?? '') == null ? 'Number' : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _reassignController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Accept/reject window (min)'),
                          validator: (v) => int.tryParse(v ?? '') == null ? 'Number' : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (_error != null) ...[
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            height: 18, width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Create event'),
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
