import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Sangeet · 1 Dec 2026 · Grand Palace".
///
/// Event names are unique per caterer as of 0016, so the name alone is no
/// longer ambiguous — but the date is what a host actually recognises an
/// event by when several are listed, and picking the wrong one means
/// designing a floor or starting a round on somebody else's night.
///
/// Missing pieces are dropped rather than rendered as gaps, and an
/// unparseable date falls back to its raw text instead of disappearing.
String eventPickerLabel(Map<String, dynamic> event) {
  final name = event['name'] as String?;
  final venue = event['venue_name'] as String?;
  final raw = event['date'] as String?;
  final date = raw == null ? null : DateTime.tryParse(raw);
  final when = date == null ? raw : '${date.day} ${_months[date.month - 1]} ${date.year}';
  return [name, when, venue]
      .where((part) => part != null && part.trim().isNotEmpty)
      .join(' · ');
}

/// Shared "which event am I working on" header used by every event-scoped
/// host screen (floor design, menu, ...). Fetches the caterer's events
/// once, renders a dropdown, and hands the currently selected event id to
/// [builder] for the actual screen content below it.
class EventPicker extends StatefulWidget {
  const EventPicker({super.key, required this.builder, this.onEventChanged});

  final Widget Function(BuildContext context, String eventId) builder;
  final ValueChanged<String?>? onEventChanged;

  @override
  State<EventPicker> createState() => _EventPickerState();
}

class _EventPickerState extends State<EventPicker> {
  List<Map<String, dynamic>>? _events;
  String? _selectedEventId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) throw StateError('Not logged in');
      final caterer = await supabase
          .from('caterers')
          .select('id')
          .eq('auth_user_id', userId)
          .single();
      final events = await supabase
          .from('events')
          .select('id, name, venue_name, date')
          .eq('caterer_id', caterer['id'])
          .order('date');
      final list = List<Map<String, dynamic>>.from(events);
      final selected = list.isNotEmpty ? list.first['id'] as String : null;
      setState(() {
        _events = list;
        _selectedEventId = selected;
      });
      widget.onEventChanged?.call(selected);
    } catch (e) {
      setState(() => _error = 'Could not reach Supabase: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_events == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_events!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Create an event first, then come back here.'),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: DropdownButtonFormField<String>(
            initialValue: _selectedEventId,
            decoration: const InputDecoration(labelText: 'Event'),
            // isExpanded so a long label ellipsises instead of overflowing —
            // the label now carries date and venue, not just the name.
            isExpanded: true,
            items: [
              for (final e in _events!)
                DropdownMenuItem(
                  value: e['id'] as String,
                  child: Text(eventPickerLabel(e), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              setState(() => _selectedEventId = v);
              widget.onEventChanged?.call(v);
            },
          ),
        ),
        Expanded(child: widget.builder(context, _selectedEventId!)),
      ],
    );
  }
}
