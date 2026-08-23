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
      // Definer RPCs rather than direct table reads: `menu_items` and
      // `sections` are scoped to the owning caterer and to guests holding a
      // booking (0022), and a guest browsing the floor before they book has
      // neither. Naming the event id from their QR is the access rule, the
      // same way get_public_event_info works for the landing page.
      final menuRows = await supabase.rpc(
        'public_event_menu',
        params: {'p_event_id': widget.eventId},
      );
      final sectionRows = await supabase.rpc(
        'public_event_sections',
        params: {'p_event_id': widget.eventId},
      );
      setState(() {
        _menuItems = List<Map<String, dynamic>>.from(menuRows)
            .map((r) => _MenuItem(name: r['name'] as String, dietary: r['dietary'] as String))
            .toList();
        _sections = List<Map<String, dynamic>>.from(sectionRows).map((r) {
          // Capacity is summed server-side now, so this no longer needs to
          // read `tables` at all.
          return _Section(
            id: r['id'] as String,
            name: r['name'] as String,
            type: r['type'] as String,
            capacity: r['capacity'] as int,
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
