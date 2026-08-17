import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

/// Seeded into a new event's menu so the host starts with somewhere to put
/// dishes rather than an empty screen and a "create a section first" wall.
const _defaultSectionNames = ['Starters', 'Mains', 'Desserts', 'Beverages'];

/// Dishes whose section was deleted keep existing (menu_section_id is set
/// null, not cascaded) and are collected under this pseudo-section, which
/// has no row in menu_sections and can't be renamed, reordered, or deleted.
const _uncategorisedId = '__uncategorised__';

class _MenuItem {
  _MenuItem({
    required this.id,
    required this.name,
    required this.dietary,
    required this.sectionId,
    required this.displayOrder,
  });
  final String id;
  final String name;

  /// 'veg' | 'nonveg' — the dietary tag. Deliberately not called `type`:
  /// a dish's course and its dietary tag are separate dimensions, and the
  /// column was renamed in 0012 to stop the two reading alike.
  final String dietary;
  final String? sectionId;
  final int displayOrder;
}

class _MenuSection {
  _MenuSection({required this.id, required this.name, required this.displayOrder});
  final String id;
  final String name;
  final int displayOrder;

  bool get isUncategorised => id == _uncategorisedId;
}

/// Real menu editor: dishes grouped into ordered courses, each dish tagged
/// veg or non-veg. Sections and dishes are both drag-reorderable, and dishes
/// can be dragged between sections.
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
          if (_eventId != null) ...[
            IconButton(
              icon: const Icon(Icons.visibility_outlined),
              tooltip: 'Preview menu',
              onPressed: () => _contentKey.currentState?.showPreview(),
            ),
            IconButton(
              icon: const Icon(Icons.list_alt_outlined),
              tooltip: 'Manage sections',
              onPressed: () => _contentKey.currentState?.showSectionManager(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload',
              onPressed: () => _contentKey.currentState?.reload(),
            ),
          ],
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
  List<_MenuSection>? _sections;
  String? _error;
  bool _mutating = false;

  final _searchController = TextEditingController();
  String _search = '';
  String _dietaryFilter = 'all';
  final Set<String> _collapsed = {};

  bool _selectMode = false;
  final Set<String> _selected = {};

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
      _sections = null;
      _selected.clear();
      _selectMode = false;
      reload();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    setState(() => _error = null);
    try {
      final sectionRows = await supabase
          .from('menu_sections')
          .select('id, name, display_order')
          .eq('event_id', widget.eventId)
          .order('display_order');
      final itemRows = await supabase
          .from('menu_items')
          .select('id, name, dietary, menu_section_id, display_order')
          .eq('event_id', widget.eventId)
          .order('display_order');
      if (!mounted) return;
      setState(() {
        _sections = List<Map<String, dynamic>>.from(sectionRows)
            .map((r) => _MenuSection(
                  id: r['id'] as String,
                  name: r['name'] as String,
                  displayOrder: r['display_order'] as int,
                ))
            .toList();
        _items = List<Map<String, dynamic>>.from(itemRows)
            .map((r) => _MenuItem(
                  id: r['id'] as String,
                  name: r['name'] as String,
                  dietary: r['dietary'] as String,
                  sectionId: r['menu_section_id'] as String?,
                  displayOrder: r['display_order'] as int,
                ))
            .toList();
        _selected.removeWhere((id) => !_items!.any((i) => i.id == id));
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load menu: $e');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _mutate(String failureMessage, Future<void> Function() action) async {
    setState(() => _mutating = true);
    try {
      await action();
      await reload();
    } catch (e) {
      _showError('$failureMessage: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  // ── sections ──────────────────────────────────────────────────────────

  Future<void> seedDefaultSections() => _mutate('Could not create sections', () async {
        await supabase.from('menu_sections').insert([
          for (var i = 0; i < _defaultSectionNames.length; i++)
            {'event_id': widget.eventId, 'name': _defaultSectionNames[i], 'display_order': i},
        ]);
      });

  Future<void> _addSection(String name) => _mutate('Could not add section', () async {
        await supabase.from('menu_sections').insert({
          'event_id': widget.eventId,
          'name': name,
          'display_order': _sections?.length ?? 0,
        });
      });

  Future<void> _renameSection(_MenuSection section, String name) =>
      _mutate('Could not rename section', () async {
        await supabase.from('menu_sections').update({'name': name}).eq('id', section.id);
      });

  Future<void> _deleteSection(_MenuSection section) => _mutate('Could not delete section', () async {
        await supabase.from('menu_sections').delete().eq('id', section.id);
      });

  /// Persists the whole ordering in one pass. display_order is dense and
  /// 0-based after every move, so a later insert appending at length always
  /// lands last instead of colliding with an existing row.
  Future<void> _persistSectionOrder(List<_MenuSection> ordered) =>
      _mutate('Could not reorder sections', () async {
        for (var i = 0; i < ordered.length; i++) {
          if (ordered[i].displayOrder == i) continue;
          await supabase.from('menu_sections').update({'display_order': i}).eq('id', ordered[i].id);
        }
      });

  Future<void> _persistItemPlacement(List<_MenuItem> ordered, String? sectionId) =>
      _mutate('Could not reorder items', () async {
        for (var i = 0; i < ordered.length; i++) {
          final item = ordered[i];
          if (item.displayOrder == i && item.sectionId == sectionId) continue;
          await supabase
              .from('menu_items')
              .update({'display_order': i, 'menu_section_id': sectionId}).eq('id', item.id);
        }
      });

  // ── items ─────────────────────────────────────────────────────────────

  Future<void> _addItem(String name, String dietary, String? sectionId) async {
    final siblings = _itemsIn(sectionId).length;
    await supabase.from('menu_items').insert({
      'event_id': widget.eventId,
      'name': name,
      'dietary': dietary,
      'menu_section_id': sectionId,
      'display_order': siblings,
    });
  }

  Future<void> _updateItem(_MenuItem item, String name, String dietary, String? sectionId) async {
    await supabase.from('menu_items').update({
      'name': name,
      'dietary': dietary,
      'menu_section_id': sectionId,
    }).eq('id', item.id);
  }

  Future<void> _deleteItem(_MenuItem item) => _mutate(
        'Could not delete menu item',
        () async => supabase.from('menu_items').delete().eq('id', item.id),
      );

  Future<void> _bulkDelete() => _mutate('Could not delete items', () async {
        await supabase.from('menu_items').delete().inFilter('id', _selected.toList());
        setState(() {
          _selected.clear();
          _selectMode = false;
        });
      });

  Future<void> _bulkMove(String? sectionId) => _mutate('Could not move items', () async {
        var next = _itemsIn(sectionId).length;
        for (final id in _selected) {
          await supabase
              .from('menu_items')
              .update({'menu_section_id': sectionId, 'display_order': next++}).eq('id', id);
        }
        setState(() {
          _selected.clear();
          _selectMode = false;
        });
      });

  // ── grouping / filtering ──────────────────────────────────────────────

  List<_MenuItem> _itemsIn(String? sectionId) {
    final all = _items ?? const <_MenuItem>[];
    final matching = sectionId == null || sectionId == _uncategorisedId
        ? all.where((i) => i.sectionId == null)
        : all.where((i) => i.sectionId == sectionId);
    return matching.toList()..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
  }

  bool _matchesFilters(_MenuItem item) {
    if (_dietaryFilter != 'all' && item.dietary != _dietaryFilter) return false;
    if (_search.isEmpty) return true;
    return item.name.toLowerCase().contains(_search.toLowerCase());
  }

  /// Real sections in display order, plus the Uncategorised bucket appended
  /// only when something actually landed in it.
  List<_MenuSection> get _displaySections {
    final sections = [...?_sections]..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
    if (_itemsIn(_uncategorisedId).isNotEmpty) {
      sections.add(_MenuSection(
        id: _uncategorisedId,
        name: 'Uncategorised',
        displayOrder: sections.length,
      ));
    }
    return sections;
  }

  bool get _filtering => _search.isNotEmpty || _dietaryFilter != 'all';

  // ── dialogs ───────────────────────────────────────────────────────────

  Future<void> showAddItemDialog({_MenuItem? existing}) async {
    final sections = _sections ?? const <_MenuSection>[];
    if (existing == null && sections.isEmpty) {
      _showError('Add a section first — use Manage sections in the header.');
      return;
    }

    final nameController = TextEditingController(text: existing?.name ?? '');
    final nameFocus = FocusNode();
    var dietary = existing?.dietary ?? 'veg';
    var sectionId = existing?.sectionId ?? sections.first.id;
    var savedAny = false;
    String? inlineError;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          // Commits the entry. `keepOpen` drives Save & Add Another: same
          // section and dietary tag stay put so a host entering six starters
          // in a row only types the names.
          Future<void> commit({required bool keepOpen}) async {
            final name = nameController.text.trim();
            if (name.isEmpty) {
              setDialogState(() => inlineError = 'Enter a name.');
              return;
            }
            try {
              if (existing == null) {
                await _addItem(name, dietary, sectionId);
              } else {
                await _updateItem(existing, name, dietary, sectionId);
              }
              savedAny = true;
            } catch (e) {
              setDialogState(() => inlineError = 'Could not save: $e');
              return;
            }
            if (!keepOpen) {
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              return;
            }
            await reload();
            nameController.clear();
            setDialogState(() => inlineError = null);
            nameFocus.requestFocus();
          }

          return AlertDialog(
            title: Text(existing == null ? 'Add menu item' : 'Edit menu item'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    focusNode: nameFocus,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name'),
                    onSubmitted: (_) => commit(keepOpen: false),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: sectionId,
                    decoration: const InputDecoration(labelText: 'Section'),
                    items: [
                      for (final s in sections)
                        DropdownMenuItem(value: s.id, child: Text(s.name)),
                    ],
                    onChanged: (v) => setDialogState(() => sectionId = v!),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'veg', label: Text('Veg')),
                      ButtonSegment(value: 'nonveg', label: Text('Non-veg')),
                    ],
                    selected: {dietary},
                    onSelectionChanged: (v) => setDialogState(() => dietary = v.first),
                  ),
                  if (inlineError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      inlineError!,
                      style: TextStyle(color: Theme.of(dialogContext).colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              if (existing == null)
                TextButton(
                  onPressed: () => commit(keepOpen: true),
                  child: const Text('Save & Add Another'),
                ),
              FilledButton(
                onPressed: () => commit(keepOpen: false),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    nameController.dispose();
    nameFocus.dispose();
    // Save & Add Another reloads as it goes; this catches the final Save and
    // the case where the host adds a few then cancels out.
    if (savedAny && mounted) await reload();
  }

  Future<void> showSectionManager() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final sections = _displaySections.where((s) => !s.isUncategorised).toList();
          return AlertDialog(
            title: const Text('Menu sections'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (sections.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No sections yet.'),
                    )
                  else
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final s in sections)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(s.name),
                                subtitle: Text('${_itemsIn(s.id).length} item(s)'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined, size: 20),
                                      tooltip: 'Rename',
                                      onPressed: () async {
                                        final name = await _promptForName(
                                          title: 'Rename section',
                                          initial: s.name,
                                        );
                                        if (name != null) {
                                          await _renameSection(s, name);
                                          setDialogState(() {});
                                        }
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, size: 20),
                                      tooltip: 'Delete',
                                      onPressed: () async {
                                        final count = _itemsIn(s.id).length;
                                        final ok = await _confirm(
                                          'Delete ${s.name}?',
                                          count == 0
                                              ? 'This section has no items.'
                                              : 'Its $count item(s) stay on the menu and move to '
                                                  'Uncategorised — they are not deleted.',
                                        );
                                        if (ok) {
                                          await _deleteSection(s);
                                          setDialogState(() {});
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add section'),
                          onPressed: () async {
                            final name = await _promptForName(title: 'New section');
                            if (name != null) {
                              await _addSection(name);
                              setDialogState(() {});
                            }
                          },
                        ),
                        if (sections.isEmpty)
                          OutlinedButton.icon(
                            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                            label: const Text('Use defaults'),
                            onPressed: () async {
                              await seedDefaultSections();
                              setDialogState(() {});
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<String?> _promptForName({required String title, String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Section name'),
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    final name = controller.text.trim();
    controller.dispose();
    return result == true && name.isNotEmpty ? name : null;
  }

  Future<bool> _confirm(String title, String message) async {
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

  Future<void> showPreview() async {
    final eventRow = await supabase
        .from('events')
        .select('name, venue_name, date')
        .eq('id', widget.eventId)
        .single();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _MenuPreviewDialog(
        eventName: eventRow['name'] as String,
        venue: eventRow['venue_name'] as String,
        date: eventRow['date'] as String,
        sections: _displaySections,
        itemsFor: _itemsIn,
      ),
    );
  }

  // ── build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_items == null || _sections == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sections!.isEmpty && _items!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('No menu yet — start with the usual courses, or add your own.'),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Create default sections'),
                onPressed: _mutating ? null : seedDefaultSections,
              ),
              TextButton(
                onPressed: _mutating ? null : showSectionManager,
                child: const Text('Set up sections myself'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _filterBar(),
        if (_selectMode) _bulkActionBar(),
        Expanded(child: _sectionList()),
      ],
    );
  }

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'Search dishes',
                border: const OutlineInputBorder(),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _search = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          const SizedBox(width: 12),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'all', label: Text('All')),
              ButtonSegment(value: 'veg', label: Text('Veg')),
              ButtonSegment(value: 'nonveg', label: Text('Non-veg')),
            ],
            selected: {_dietaryFilter},
            onSelectionChanged: (v) => setState(() => _dietaryFilter = v.first),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _mutating
                ? null
                : () => setState(() {
                      _selectMode = !_selectMode;
                      _selected.clear();
                    }),
            child: Text(_selectMode ? 'Done' : 'Select'),
          ),
        ],
      ),
    );
  }

  Widget _bulkActionBar() {
    final sections = _displaySections.where((s) => !s.isUncategorised).toList();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Text('${_selected.length} selected'),
            const Spacer(),
            PopupMenuButton<String>(
              enabled: !_mutating && _selected.isNotEmpty && sections.isNotEmpty,
              tooltip: 'Move to section',
              icon: const Icon(Icons.drive_file_move_outline),
              onSelected: _bulkMove,
              itemBuilder: (context) => [
                for (final s in sections) PopupMenuItem(value: s.id, child: Text(s.name)),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete selected',
              onPressed: _mutating || _selected.isEmpty
                  ? null
                  : () async {
                      if (await _confirm(
                        'Delete ${_selected.length} item(s)?',
                        'This removes them from the menu guests see.',
                      )) {
                        await _bulkDelete();
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionList() {
    final sections = _displaySections;

    // Reordering is meaningless against a filtered subset — what the host
    // drags past isn't what's actually adjacent — so while a filter is on,
    // the list renders read-only.
    if (_filtering) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
        children: [
          for (final section in sections)
            ..._filteredSectionBlock(section),
          if (sections.every((s) => _itemsIn(s.id).where(_matchesFilters).isEmpty))
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Center(child: Text('No dishes match.')),
            ),
        ],
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      itemCount: sections.length,
      // onReorderItem (not onReorder) already accounts for the removal at
      // oldIndex, so newIndex needs no adjusting here.
      onReorderItem: (oldIndex, newIndex) {
        final reorderable = sections.where((s) => !s.isUncategorised).toList();
        if (oldIndex >= reorderable.length || newIndex >= reorderable.length) return;
        final moved = reorderable.removeAt(oldIndex);
        reorderable.insert(newIndex, moved);
        _persistSectionOrder(reorderable);
      },
      itemBuilder: (context, index) {
        final section = sections[index];
        return _sectionCard(section, index, key: ValueKey('section-${section.id}'));
      },
    );
  }

  List<Widget> _filteredSectionBlock(_MenuSection section) {
    final items = _itemsIn(section.id).where(_matchesFilters).toList();
    if (items.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(section.name, style: Theme.of(context).textTheme.titleMedium),
      ),
      for (final item in items) _itemTile(item, draggableIndex: null),
    ];
  }

  Widget _sectionCard(_MenuSection section, int index, {required Key key}) {
    final items = _itemsIn(section.id);
    final collapsed = _collapsed.contains(section.id);

    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() {
              collapsed ? _collapsed.remove(section.id) : _collapsed.add(section.id);
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
              child: Row(
                children: [
                  if (section.isUncategorised)
                    const SizedBox(width: 40)
                  else
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.drag_indicator, size: 20),
                      ),
                    ),
                  Icon(collapsed ? Icons.expand_more : Icons.expand_less, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      section.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    '${items.length}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed) ...[
            const Divider(height: 1),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  section.isUncategorised
                      ? 'Nothing here.'
                      : 'No dishes yet — drag one here, or use + Item.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              // Nested reorderable: handles ordering *within* this section.
              // Moving a dish to another section goes through the row's
              // section menu rather than a cross-list drag, which
              // ReorderableListView can't express on its own.
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: items.length,
                onReorderItem: (oldIndex, newIndex) {
                  final reordered = [...items];
                  final moved = reordered.removeAt(oldIndex);
                  reordered.insert(newIndex, moved);
                  _persistItemPlacement(reordered, section.isUncategorised ? null : section.id);
                },
                itemBuilder: (context, i) => _itemTile(
                  items[i],
                  draggableIndex: i,
                  key: ValueKey('item-${items[i].id}'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _itemTile(_MenuItem item, {required int? draggableIndex, Key? key}) {
    final isVeg = item.dietary == 'veg';
    final selected = _selected.contains(item.id);
    final otherSections =
        _displaySections.where((s) => s.id != item.sectionId && !s.isUncategorised).toList();

    return ListTile(
      key: key ?? ValueKey('item-${item.id}'),
      dense: true,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_selectMode)
            Checkbox(
              value: selected,
              onChanged: (_) => setState(() {
                selected ? _selected.remove(item.id) : _selected.add(item.id);
              }),
            )
          else if (draggableIndex != null)
            ReorderableDragStartListener(
              index: draggableIndex,
              child: const Icon(Icons.drag_indicator, size: 20),
            )
          else
            const SizedBox(width: 20),
          const SizedBox(width: 8),
          Icon(
            isVeg ? Icons.eco_outlined : Icons.set_meal_outlined,
            color: isVeg ? Colors.green : Colors.redAccent,
            size: 20,
          ),
        ],
      ),
      title: Text(item.name),
      trailing: _selectMode
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (otherSections.isNotEmpty)
                  PopupMenuButton<String>(
                    tooltip: 'Move to section',
                    icon: const Icon(Icons.drive_file_move_outline, size: 20),
                    enabled: !_mutating,
                    onSelected: (sectionId) => _mutate('Could not move item', () async {
                      await supabase.from('menu_items').update({
                        'menu_section_id': sectionId,
                        'display_order': _itemsIn(sectionId).length,
                      }).eq('id', item.id);
                    }),
                    itemBuilder: (context) => [
                      for (final s in otherSections)
                        PopupMenuItem(value: s.id, child: Text(s.name)),
                    ],
                  ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: _mutating ? null : () => showAddItemDialog(existing: item),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: _mutating
                      ? null
                      : () async {
                          if (await _confirm(
                            'Delete ${item.name}?',
                            'This removes it from the menu guests see.',
                          )) {
                            await _deleteItem(item);
                          }
                        },
                ),
              ],
            ),
      onTap: _selectMode
          ? () => setState(() {
                selected ? _selected.remove(item.id) : _selected.add(item.id);
              })
          : null,
    );
  }
}

/// Guest-facing menu card — what the host would print or hand round, so it
/// drops every editing affordance and shows only courses, dishes, and
/// dietary badges.
class _MenuPreviewDialog extends StatelessWidget {
  const _MenuPreviewDialog({
    required this.eventName,
    required this.venue,
    required this.date,
    required this.sections,
    required this.itemsFor,
  });

  final String eventName;
  final String venue;
  final String date;
  final List<_MenuSection> sections;
  final List<_MenuItem> Function(String?) itemsFor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final populated = sections.where((s) => itemsFor(s.id).isNotEmpty).toList();

    return AlertDialog(
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(eventName, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text('$venue · $date', style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              const Divider(),
              if (populated.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('No dishes on the menu yet.'),
                )
              else
                for (final section in populated) ...[
                  const SizedBox(height: 12),
                  Text(
                    section.name.toUpperCase(),
                    style: theme.textTheme.titleSmall?.copyWith(letterSpacing: 1.5),
                  ),
                  const SizedBox(height: 8),
                  for (final item in itemsFor(section.id))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            item.dietary == 'veg' ? Icons.circle_outlined : Icons.change_history,
                            size: 12,
                            color: item.dietary == 'veg' ? Colors.green : Colors.redAccent,
                          ),
                          const SizedBox(width: 8),
                          Flexible(child: Text(item.name, textAlign: TextAlign.center)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              const Divider(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
