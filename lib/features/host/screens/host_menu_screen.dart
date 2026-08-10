import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

class _MenuItem {
  _MenuItem({required this.id, required this.name, required this.type});
  final String id;
  final String name;
  final String type;
}

/// Real menu editor: add/edit/delete menu items (name, veg or non-veg) for
/// the selected event.
class HostMenuScreen extends StatefulWidget {
  const HostMenuScreen({super.key});

  @override
  State<HostMenuScreen> createState() => _HostMenuScreenState();
}

class _HostMenuScreenState extends State<HostMenuScreen> {
  String? _eventId;
  final _contentKey = GlobalKey<_MenuContentState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Menu'),
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
        builder: (context, eventId) => _MenuContent(key: _contentKey, eventId: eventId),
      ),
      floatingActionButton: _eventId != null
          ? FloatingActionButton.extended(
              onPressed: () => _contentKey.currentState?.showAddItemDialog(),
              icon: const Icon(Icons.add),
              label: const Text('Item'),
            )
          : null,
    );
  }
}

class _MenuContent extends StatefulWidget {
  const _MenuContent({super.key, required this.eventId});
  final String eventId;

  @override
  State<_MenuContent> createState() => _MenuContentState();
}

class _MenuContentState extends State<_MenuContent> {
  List<_MenuItem>? _items;
  String? _error;
  bool _mutating = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(covariant _MenuContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      _items = null;
      reload();
    }
  }

  Future<void> reload() async {
    setState(() => _error = null);
    try {
      final rows = await supabase
          .from('menu_items')
          .select('id, name, type')
          .eq('event_id', widget.eventId)
          .order('name');
      setState(() {
        _items = List<Map<String, dynamic>>.from(rows)
            .map((r) => _MenuItem(id: r['id'] as String, name: r['name'] as String, type: r['type'] as String))
            .toList();
      });
    } catch (e) {
      setState(() => _error = 'Could not load menu: $e');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addItem(String name, String type) async {
    setState(() => _mutating = true);
    try {
      await supabase.from('menu_items').insert({
        'event_id': widget.eventId,
        'name': name,
        'type': type,
      });
      await reload();
    } catch (e) {
      _showError('Could not add menu item: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _updateItem(_MenuItem item, String name, String type) async {
    setState(() => _mutating = true);
    try {
      await supabase.from('menu_items').update({'name': name, 'type': type}).eq('id', item.id);
      await reload();
    } catch (e) {
      _showError('Could not update menu item: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _deleteItem(_MenuItem item) async {
    setState(() => _mutating = true);
    try {
      await supabase.from('menu_items').delete().eq('id', item.id);
      await reload();
    } catch (e) {
      _showError('Could not delete menu item: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> showAddItemDialog({_MenuItem? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    var type = existing?.type ?? 'veg';
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add menu item' : 'Edit menu item'),
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
        await _addItem(nameController.text.trim(), type);
      } else {
        await _updateItem(existing, nameController.text.trim(), type);
      }
    }
  }

  Future<bool> _confirmDelete(_MenuItem item) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${item.name}?'),
        content: const Text('This removes it from the menu guests see.'),
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

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items!.isEmpty) {
      return const Center(child: Text('No menu items yet — add one to get started.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _items!.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final item = _items![i];
        return Card(
          child: ListTile(
            leading: Icon(
              item.type == 'veg' ? Icons.eco_outlined : Icons.set_meal_outlined,
              color: item.type == 'veg' ? Colors.green : Colors.redAccent,
            ),
            title: Text(item.name),
            subtitle: Text(item.type == 'veg' ? 'Veg' : 'Non-veg'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _mutating ? null : () => showAddItemDialog(existing: item),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _mutating
                      ? null
                      : () async {
                          if (await _confirmDelete(item)) {
                            await _deleteItem(item);
                          }
                        },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
