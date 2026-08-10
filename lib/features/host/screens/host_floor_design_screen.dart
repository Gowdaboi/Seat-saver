import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

class _Table {
  _Table({required this.id, required this.tableNumber, required this.seatCount});
  final String id;
  final int tableNumber;
  final int seatCount;
}

class _Section {
  _Section({required this.id, required this.name, required this.type, required this.tables});
  final String id;
  final String name;
  final String type;
  final List<_Table> tables;

  // Derived, not stored — see project-spec.md "Resolved decisions".
  int get capacity => tables.fold(0, (sum, t) => sum + t.seatCount);
}

/// Real floor design editor: sections (name + type) containing tables
/// (table_number auto-assigned, seat_count chosen by the host), with each
/// table's seats created to match. Deleting a section/table cascades to its
/// tables/seats at the DB level (on delete cascade), so this only needs to
/// delete the top-level row.
class HostFloorDesignScreen extends StatefulWidget {
  const HostFloorDesignScreen({super.key});

  @override
  State<HostFloorDesignScreen> createState() => _HostFloorDesignScreenState();
}

class _HostFloorDesignScreenState extends State<HostFloorDesignScreen> {
  String? _eventId;
  final _contentKey = GlobalKey<_FloorContentState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Design floor'),
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
        builder: (context, eventId) => _FloorContent(key: _contentKey, eventId: eventId),
      ),
      floatingActionButton: _eventId != null
          ? FloatingActionButton.extended(
              onPressed: () => _contentKey.currentState?.showAddSectionDialog(),
              icon: const Icon(Icons.add),
              label: const Text('Section'),
            )
          : null,
    );
  }
}

class _FloorContent extends StatefulWidget {
  const _FloorContent({super.key, required this.eventId});
  final String eventId;

  @override
  State<_FloorContent> createState() => _FloorContentState();
}

class _FloorContentState extends State<_FloorContent> {
  List<_Section>? _sections;
  String? _error;
  bool _mutating = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(covariant _FloorContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      _sections = null;
      reload();
    }
  }

  Future<void> reload() async {
    setState(() => _error = null);
    try {
      final rows = await supabase
          .from('sections')
          .select('id, name, type, display_order, tables(id, table_number, seat_count)')
          .eq('event_id', widget.eventId)
          .order('display_order');
      setState(() {
        _sections = List<Map<String, dynamic>>.from(rows).map((r) {
          final tables = (r['tables'] as List)
              .map((t) => _Table(
                    id: t['id'] as String,
                    tableNumber: t['table_number'] as int,
                    seatCount: t['seat_count'] as int,
                  ))
              .toList()
            ..sort((a, b) => a.tableNumber.compareTo(b.tableNumber));
          return _Section(
            id: r['id'] as String,
            name: r['name'] as String,
            type: r['type'] as String,
            tables: tables,
          );
        }).toList();
      });
    } catch (e) {
      setState(() => _error = 'Could not load floor: $e');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addSection(String name, String type) async {
    setState(() => _mutating = true);
    try {
      await supabase.from('sections').insert({
        'event_id': widget.eventId,
        'name': name,
        'type': type,
        'display_order': _sections?.length ?? 0,
      });
      await reload();
    } catch (e) {
      _showError('Could not add section: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _updateSection(_Section section, String name, String type) async {
    setState(() => _mutating = true);
    try {
      await supabase.from('sections').update({'name': name, 'type': type}).eq('id', section.id);
      await reload();
    } catch (e) {
      _showError('Could not update section: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _deleteSection(_Section section) async {
    setState(() => _mutating = true);
    try {
      await supabase.from('sections').delete().eq('id', section.id);
      await reload();
    } catch (e) {
      _showError('Could not delete section: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _addTable(_Section section, int seatCount) async {
    setState(() => _mutating = true);
    try {
      final allTableNumbers = _sections!.expand((s) => s.tables.map((t) => t.tableNumber));
      final nextNumber =
          allTableNumbers.isEmpty ? 1 : allTableNumbers.reduce((a, b) => a > b ? a : b) + 1;
      final inserted = await supabase
          .from('tables')
          .insert({
            'event_id': widget.eventId,
            'section_id': section.id,
            'table_number': nextNumber,
            'seat_count': seatCount,
          })
          .select('id')
          .single();
      final tableId = inserted['id'] as String;
      await supabase.from('seats').insert([
        for (var i = 1; i <= seatCount; i++) {'table_id': tableId, 'seat_number': i, 'status': 'available'},
      ]);
      await reload();
    } catch (e) {
      _showError('Could not add table: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _deleteTable(_Table table) async {
    setState(() => _mutating = true);
    try {
      await supabase.from('tables').delete().eq('id', table.id);
      await reload();
    } catch (e) {
      _showError('Could not delete table: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<bool> _confirmDelete(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> showAddSectionDialog({_Section? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    var type = existing?.type ?? 'mixed';
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add section' : 'Edit section'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'veg', child: Text('Veg')),
                  DropdownMenuItem(value: 'nonveg', child: Text('Non-veg')),
                  DropdownMenuItem(value: 'mixed', child: Text('Mixed')),
                ],
                onChanged: (v) => setDialogState(() => type = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result == true && nameController.text.trim().isNotEmpty) {
      if (existing == null) {
        await _addSection(nameController.text.trim(), type);
      } else {
        await _updateSection(existing, nameController.text.trim(), type);
      }
    }
  }

  Future<void> _showAddTableDialog(_Section section) async {
    final seatController = TextEditingController(text: '6');
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add table to ${section.name}'),
        content: TextField(
          controller: seatController,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Seats at this table'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    final seatCount = int.tryParse(seatController.text);
    if (result == true && seatCount != null && seatCount > 0) {
      await _addTable(section, seatCount);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_sections == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sections!.isEmpty) {
      return const Center(child: Text('No sections yet — add one to start designing the floor.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _sections!.length,
      itemBuilder: (context, i) => _sectionCard(_sections![i]),
    );
  }

  Widget _sectionCard(_Section section) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${section.name} · ${section.capacity} seats',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Chip(label: Text(section.type)),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _mutating ? null : () => showAddSectionDialog(existing: section),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _mutating
                      ? null
                      : () async {
                          if (await _confirmDelete(
                            'Delete ${section.name}?',
                            'This removes all ${section.tables.length} table(s) and their seats in this section.',
                          )) {
                            await _deleteSection(section);
                          }
                        },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final table in section.tables)
                  InputChip(
                    label: Text('Table ${table.tableNumber} · ${table.seatCount} seats'),
                    onDeleted: _mutating
                        ? null
                        : () async {
                            if (await _confirmDelete(
                              'Delete table ${table.tableNumber}?',
                              'This removes its ${table.seatCount} seat(s).',
                            )) {
                              await _deleteTable(table);
                            }
                          },
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Add table'),
                  onPressed: _mutating ? null : () => _showAddTableDialog(section),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
