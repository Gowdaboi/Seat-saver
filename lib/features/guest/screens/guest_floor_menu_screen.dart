import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/supabase_client.dart';

class _Section {
  _Section({required this.id, required this.name, required this.type, required this.capacity});
  final String id;
  final String name;
  final String type;
  final int capacity;
}

class _MenuItem {
  _MenuItem({required this.name, required this.dietary});
  final String name;
  // 'veg' | 'nonveg'. Named dietary, not type, to keep it distinct from
  // _Section.type above — that one is the floor zone's veg/nonveg/mixed
  // designation, and both appear on this screen.
  final String dietary;
}

/// Real menu + section list for the event, scoped by RLS to what the host
/// has actually configured. Picking a section scopes the seat picker to
/// that section's tables (project-spec.md "Resolved decisions").
class GuestFloorMenuScreen extends StatefulWidget {
  const GuestFloorMenuScreen({super.key, required this.eventId});
  final String eventId;

  @override
  State<GuestFloorMenuScreen> createState() => _GuestFloorMenuScreenState();
}

class _GuestFloorMenuScreenState extends State<GuestFloorMenuScreen> {
  List<_MenuItem>? _menuItems;
  List<_Section>? _sections;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final menuRows = await supabase
          .from('menu_items')
          .select('name, dietary')
          .eq('event_id', widget.eventId)
          .order('name');
      final sectionRows = await supabase
          .from('sections')
          .select('id, name, type, display_order, tables(seat_count)')
          .eq('event_id', widget.eventId)
          .order('display_order');
      setState(() {
        _menuItems = List<Map<String, dynamic>>.from(menuRows)
            .map((r) => _MenuItem(name: r['name'] as String, dietary: r['dietary'] as String))
            .toList();
        _sections = List<Map<String, dynamic>>.from(sectionRows).map((r) {
          final capacity = (r['tables'] as List)
              .fold<int>(0, (sum, t) => sum + (t['seat_count'] as int));
          return _Section(
            id: r['id'] as String,
            name: r['name'] as String,
            type: r['type'] as String,
            capacity: capacity,
          );
        }).toList();
      });
    } catch (e) {
      setState(() => _error = 'Could not load event: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Menu & floor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.support_agent),
            tooltip: 'Call host',
            onPressed: () => context.push('/e/${widget.eventId}/call-host'),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : _menuItems == null || _sections == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text('Menu', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_menuItems!.isEmpty)
                      const Text('No menu published yet.')
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final item in _menuItems!)
                            Chip(
                              avatar: Icon(
                                item.dietary == 'veg' ? Icons.eco_outlined : Icons.set_meal_outlined,
                                size: 18,
                                color: item.dietary == 'veg' ? Colors.green : Colors.redAccent,
                              ),
                              label: Text(item.name),
                            ),
                        ],
                      ),
                    const SizedBox(height: 24),
                    Text('Choose a section', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_sections!.isEmpty)
                      const Text('No sections configured yet.')
                    else
                      for (final section in _sections!)
                        Card(
                          child: ListTile(
                            title: Text(section.name),
                            subtitle: Text('${section.type} · ${section.capacity} seats'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => context.push(
                              '/e/${widget.eventId}/seats?section=${section.id}',
                            ),
                          ),
                        ),
                  ],
                ),
    );
  }
}
