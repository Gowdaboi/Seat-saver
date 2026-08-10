import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';

/// Read-only recap for one past event — reservation stats, the menu, and
/// the floor design. No editing here: this is a historical record, not the
/// live editors (HostFloorDesignScreen / HostMenuScreen), which still work
/// on a past event if you genuinely need to change it, but that's not what
/// this screen is for.
class HostPastEventDetailScreen extends StatefulWidget {
  const HostPastEventDetailScreen({super.key, required this.eventId});
  final String eventId;

  @override
  State<HostPastEventDetailScreen> createState() => _HostPastEventDetailScreenState();
}

class _HostPastEventDetailScreenState extends State<HostPastEventDetailScreen> {
  Map<String, dynamic>? _event;
  int? _guestCount;
  int? _totalSeats;
  List<Map<String, dynamic>>? _menuItems;
  List<Map<String, dynamic>>? _sections;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final event = await supabase
          .from('events')
          .select('name, venue_name, date, service_type')
          .eq('id', widget.eventId)
          .single();
      final bookings = await supabase
          .from('bookings')
          .select('party_size')
          .eq('event_id', widget.eventId);
      final menu = await supabase
          .from('menu_items')
          .select('name, type')
          .eq('event_id', widget.eventId)
          .order('name');
      final sections = await supabase
          .from('sections')
          .select('id, name, type, tables(seat_count)')
          .eq('event_id', widget.eventId)
          .order('display_order');

      final bookingRows = List<Map<String, dynamic>>.from(bookings);
      setState(() {
        _event = event;
        _guestCount = bookingRows.length;
        _totalSeats = bookingRows.fold<int>(0, (sum, b) => sum + (b['party_size'] as int));
        _menuItems = List<Map<String, dynamic>>.from(menu);
        _sections = List<Map<String, dynamic>>.from(sections);
      });
    } catch (e) {
      setState(() => _error = 'Could not load event: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_event?['name'] as String? ?? 'Event')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : _event == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      '${_event!['venue_name']} · ${_event!['date']} · ${_event!['service_type']}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _stat('$_guestCount', 'guests reserved\nvia the app'),
                            _stat('$_totalSeats', 'total seats\nreserved'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text('Menu', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_menuItems!.isEmpty)
                      const Text('No menu was published.')
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final item in _menuItems!)
                            Chip(
                              avatar: Icon(
                                item['type'] == 'veg' ? Icons.eco_outlined : Icons.set_meal_outlined,
                                size: 18,
                                color: item['type'] == 'veg' ? Colors.green : Colors.redAccent,
                              ),
                              label: Text(item['name'] as String),
                            ),
                        ],
                      ),
                    const SizedBox(height: 24),
                    Text('Floor design', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_sections!.isEmpty)
                      const Text('No floor design was set up.')
                    else
                      for (final section in _sections!)
                        Card(
                          child: ListTile(
                            title: Text(section['name'] as String),
                            subtitle: Text(
                              '${section['type']} · '
                              '${(section['tables'] as List).fold<int>(0, (sum, t) => sum + (t['seat_count'] as int))} seats · '
                              '${(section['tables'] as List).length} tables',
                            ),
                          ),
                        ),
                  ],
                ),
    );
  }

  Widget _stat(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
