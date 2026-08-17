import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';
import '../../shared/widgets/floor_layout.dart';
import '../widgets/event_picker.dart';

class _Section {
  _Section({
    required this.id,
    required this.name,
    required this.type,
    required this.gridRows,
    required this.defaultOrientation,
    required this.defaultSeatingSide,
    required this.tables,
  });

  final String id;
  final String name;
  final String type;
  final int gridRows;
  final TableOrientation defaultOrientation;
  final SeatingSide defaultSeatingSide;
  final List<FloorTable> tables;

  // Derived, not stored — see project-spec.md "Resolved decisions".
  int get capacity => tables.fold(0, (sum, t) => sum + t.seats.length);

  /// Only offered as a single number when every table matches; a section the
  /// host has hand-tuned shows nothing rather than a misleading average.
  int? get uniformSeatsPerTable {
    if (tables.isEmpty) return null;
    final first = tables.first.seats.length;
    return tables.every((t) => t.seats.length == first) ? first : null;
  }
}

/// Near/far only mean something once you know which way the table runs —
/// near is the top for a horizontal table and the left for a vertical one
/// (matches lib/features/shared/widgets/floor_layout.dart). These labels
/// translate that into what a host actually sees on screen.
String _seatingSideLabel(SeatingSide side, TableOrientation orientation) {
  switch (side) {
    case SeatingSide.both:
      return 'Both sides';
    case SeatingSide.near:
      return orientation == TableOrientation.horizontal ? 'Top only' : 'Left only';
    case SeatingSide.far:
      return orientation == TableOrientation.horizontal ? 'Bottom only' : 'Right only';
  }
}

/// There's no stored flag for "this section was built with Hall rows" —
/// it's inferred from the shape configure_hall_rows() always leaves behind:
/// a single column (grid_col 0 everywhere) of one-sided tables. A grid
/// section normally won't match this (it's either multiple columns, or
/// two-sided tables, or both), so the alternating aisle/touching spacing
/// only kicks in where it actually means something.
/// The gap after a hall-rows row, derived from that row's own seating_side
/// rather than an assumed odd/even pattern — 'far' means this row's open
/// edge (where its seats sit) borders the next row's seats too, so it's a
/// facing pair and needs a wide aisle; 'near' means its open edge is the
/// bar/back, so the next row sits right up against it.
double _hallRowGap(FloorTable row) => row.seatingSide == SeatingSide.far ? 24 : 3;

bool _looksLikeHallRows(_Section section) =>
    section.tables.isNotEmpty &&
    section.tables.every((t) => t.gridCol == 0 && t.seatingSide != SeatingSide.both);

/// Real floor design editor. Sections hold tables; tables hold seats. Beyond
/// adding them one at a time, the host can describe a whole section at once
/// — "8 tables, 6 seats each, 2 rows, running horizontally" — and have the
/// layout calculated (configure_section_layout, 0009). The preview under each
/// section is the exact widget the guest books from, so the arrangement the
/// host lands on is the arrangement the guest sees.
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
          .select('id, name, type, display_order, grid_rows, default_orientation, '
              'default_seating_side, '
              'tables(id, table_number, seat_count, grid_row, grid_col, orientation, seating_side, '
              'seats(id, seat_number, status))')
          .eq('event_id', widget.eventId)
          .order('display_order');
      setState(() {
        _sections = List<Map<String, dynamic>>.from(rows).map((r) {
          final tables = (r['tables'] as List).map((t) {
            final seats = List<Map<String, dynamic>>.from(t['seats'] as List)
                .map((s) => FloorSeat(
                      id: s['id'] as String,
                      seatNumber: s['seat_number'] as int,
                      status: seatStatusFromString(s['status'] as String),
                    ))
                .toList()
              ..sort((a, b) => a.seatNumber.compareTo(b.seatNumber));
            return FloorTable(
              id: t['id'] as String,
              tableNumber: t['table_number'] as int,
              gridRow: t['grid_row'] as int,
              gridCol: t['grid_col'] as int,
              orientation: orientationFromString(t['orientation'] as String?),
              seatingSide: seatingSideFromString(t['seating_side'] as String?),
              seats: seats,
            );
          }).toList()
            ..sort((a, b) => a.tableNumber.compareTo(b.tableNumber));
          return _Section(
            id: r['id'] as String,
            name: r['name'] as String,
            type: r['type'] as String,
            gridRows: r['grid_rows'] as int,
            defaultOrientation: orientationFromString(r['default_orientation'] as String?),
            defaultSeatingSide: seatingSideFromString(r['default_seating_side'] as String?),
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

  /// Every mutation here is the same shape: flip the busy flag, do the write,
  /// reload, surface anything that went wrong.
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

  Future<void> _addSection(String name, String type) => _mutate(
        'Could not add section',
        () async => supabase.from('sections').insert({
          'event_id': widget.eventId,
          'name': name,
          'type': type,
          'display_order': _sections?.length ?? 0,
        }),
      );

  Future<void> _updateSection(_Section section, String name, String type) => _mutate(
        'Could not update section',
        () async =>
            supabase.from('sections').update({'name': name, 'type': type}).eq('id', section.id),
      );

  Future<void> _deleteSection(_Section section) => _mutate(
        'Could not delete section',
        () async => supabase.from('sections').delete().eq('id', section.id),
      );

  Future<void> _configureLayout(
    _Section section,
    int tableCount,
    int seatsPerTable,
    int rows,
    TableOrientation orientation,
    SeatingSide seatingSide,
  ) =>
      _mutate('Could not build layout', () async {
        await supabase.rpc('configure_section_layout', params: {
          'p_section_id': section.id,
          'p_table_count': tableCount,
          'p_seats_per_table': seatsPerTable,
          'p_grid_rows': rows,
          'p_orientation': orientation.name,
          'p_seating_side': seatingSide.name,
        });
      });

  Future<void> _configureHallRows(_Section section, int rowCount, int seatsPerRow) =>
      _mutate('Could not build hall rows', () async {
        await supabase.rpc('configure_hall_rows', params: {
          'p_section_id': section.id,
          'p_row_count': rowCount,
          'p_seats_per_row': seatsPerRow,
        });
      });

  /// Re-flowing keeps every table and booking — only grid positions move.
  Future<void> _reflow(_Section section, int rows) => _mutate(
        'Could not rearrange',
        () async => supabase
            .rpc('reflow_section_layout', params: {'p_section_id': section.id, 'p_grid_rows': rows}),
      );

  Future<void> _setSectionOrientation(_Section section, TableOrientation orientation) =>
      _mutate('Could not rotate tables', () async {
        await supabase
            .from('tables')
            .update({'orientation': orientation.name}).eq('section_id', section.id);
        await supabase
            .from('sections')
            .update({'default_orientation': orientation.name}).eq('id', section.id);
      });

  Future<void> _rotateTable(FloorTable table) => _mutate('Could not rotate table', () async {
        final flipped = table.orientation == TableOrientation.horizontal
            ? TableOrientation.vertical
            : TableOrientation.horizontal;
        await supabase.from('tables').update({'orientation': flipped.name}).eq('id', table.id);
      });

  Future<void> _setSectionSeatingSide(_Section section, SeatingSide side) =>
      _mutate('Could not update seating side', () async {
        await supabase.from('tables').update({'seating_side': side.name}).eq('section_id', section.id);
        await supabase.from('sections').update({'default_seating_side': side.name}).eq('id', section.id);
      });

  Future<void> _setTableSeatingSide(FloorTable table, SeatingSide side) =>
      _mutate('Could not update seating side', () async {
        await supabase.from('tables').update({'seating_side': side.name}).eq('id', table.id);
      });

  Future<void> _addTable(_Section section, int seatCount) =>
      _mutate('Could not add table', () async {
        final allTableNumbers = _sections!.expand((s) => s.tables.map((t) => t.tableNumber));
        final nextNumber =
            allTableNumbers.isEmpty ? 1 : allTableNumbers.reduce((a, b) => a > b ? a : b) + 1;

        // Append to the end of the last row; the host can re-flow afterwards.
        var gridRow = 0;
        var gridCol = 0;
        if (section.tables.isNotEmpty) {
          gridRow = section.tables.map((t) => t.gridRow).reduce((a, b) => a > b ? a : b);
          gridCol = section.tables
                  .where((t) => t.gridRow == gridRow)
                  .map((t) => t.gridCol)
                  .reduce((a, b) => a > b ? a : b) +
              1;
        }

        final inserted = await supabase
            .from('tables')
            .insert({
              'event_id': widget.eventId,
              'section_id': section.id,
              'table_number': nextNumber,
              'seat_count': seatCount,
              'grid_row': gridRow,
              'grid_col': gridCol,
              'orientation': section.defaultOrientation.name,
              'seating_side': section.defaultSeatingSide.name,
            })
            .select('id')
            .single();
        await supabase.from('seats').insert([
          for (var i = 1; i <= seatCount; i++)
            {'table_id': inserted['id'] as String, 'seat_number': i, 'status': 'available'},
        ]);
      });

  Future<void> _deleteTable(FloorTable table) => _mutate(
        'Could not delete table',
        () async => supabase.from('tables').delete().eq('id', table.id),
      );

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

  Future<void> _showConfigureDialog(_Section section) async {
    final config = await showDialog<_LayoutConfig>(
      context: context,
      builder: (context) => _ConfigureLayoutDialog(section: section),
    );
    if (config == null) return;
    if (section.tables.isNotEmpty) {
      final confirmed = await _confirmDelete(
        'Rebuild ${section.name}?',
        'This replaces the section\'s current ${section.tables.length} table(s) and '
            '${section.capacity} seat(s) with the new layout. A section that has already '
            'taken bookings can\'t be rebuilt this way — delete it instead.',
      );
      if (!confirmed) return;
    }
    await _configureLayout(
      section,
      config.tableCount,
      config.seatsPerTable,
      config.rows,
      config.orientation,
      config.seatingSide,
    );
  }

  Future<void> _showConfigureHallRowsDialog(_Section section) async {
    final config = await showDialog<_HallRowsConfig>(
      context: context,
      builder: (context) => _ConfigureHallRowsDialog(section: section),
    );
    if (config == null) return;
    if (section.tables.isNotEmpty) {
      final confirmed = await _confirmDelete(
        'Rebuild ${section.name}?',
        'This replaces the section\'s current ${section.tables.length} table(s) and '
            '${section.capacity} seat(s) with the new layout. A section that has already '
            'taken bookings can\'t be rebuilt this way — delete it instead.',
      );
      if (!confirmed) return;
    }
    await _configureHallRows(section, config.rowCount, config.seatsPerRow);
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      itemCount: _sections!.length,
      itemBuilder: (context, i) => _sectionCard(_sections![i]),
    );
  }

  Widget _sectionCard(_Section section) {
    final theme = Theme.of(context);
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
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Chip(label: Text(section.type)),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit section',
                  onPressed: _mutating ? null : () => showAddSectionDialog(existing: section),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete section',
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
            const SizedBox(height: 4),
            _layoutControls(section),
            const SizedBox(height: 12),
            if (section.tables.isNotEmpty) ...[
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: FloorLayoutView(
                  tables: section.tables,
                  seatSize: 18,
                  scrollVertically: false,
                  padding: const EdgeInsets.all(12),
                  showFacingLabels: true,
                  rowGap: _looksLikeHallRows(section)
                      ? (row) => _hallRowGap(section.tables.firstWhere((t) => t.gridRow == row))
                      : null,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final table in section.tables)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InputChip(
                        label: Text('Table ${table.tableNumber} · ${table.seats.length} seats'),
                        avatar: Icon(
                          table.orientation == TableOrientation.horizontal
                              ? Icons.horizontal_rule
                              : Icons.more_vert,
                          size: 18,
                        ),
                        tooltip: 'Tap to rotate this table',
                        onPressed: _mutating ? null : () => _rotateTable(table),
                        onDeleted: _mutating
                            ? null
                            : () async {
                                if (await _confirmDelete(
                                  'Delete table ${table.tableNumber}?',
                                  'This removes its ${table.seats.length} seat(s).',
                                )) {
                                  await _deleteTable(table);
                                }
                              },
                      ),
                      PopupMenuButton<SeatingSide>(
                        tooltip: 'Seating side — ${_seatingSideLabel(table.seatingSide, table.orientation)}',
                        enabled: !_mutating,
                        icon: const Icon(Icons.event_seat_outlined, size: 18),
                        onSelected: (side) => _setTableSeatingSide(table, side),
                        itemBuilder: (context) => [
                          for (final side in SeatingSide.values)
                            CheckedPopupMenuItem(
                              value: side,
                              checked: table.seatingSide == side,
                              child: Text(_seatingSideLabel(side, table.orientation)),
                            ),
                        ],
                      ),
                    ],
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

  Widget _layoutControls(_Section section) {
    final hasTables = section.tables.isNotEmpty;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.grid_on, size: 18),
          label: Text(hasTables ? 'Rebuild layout' : 'Build layout'),
          onPressed: _mutating ? null : () => _showConfigureDialog(section),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.view_agenda_outlined, size: 18),
          label: const Text('Hall rows'),
          onPressed: _mutating ? null : () => _showConfigureHallRowsDialog(section),
        ),
        if (hasTables) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Rows'),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                tooltip: 'Fewer rows',
                onPressed: _mutating || section.gridRows <= 1
                    ? null
                    : () => _reflow(section, section.gridRows - 1),
              ),
              Text('${section.gridRows}'),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'More rows',
                onPressed: _mutating || section.gridRows >= section.tables.length
                    ? null
                    : () => _reflow(section, section.gridRows + 1),
              ),
            ],
          ),
          SegmentedButton<TableOrientation>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: TableOrientation.horizontal,
                icon: Icon(Icons.table_rows_outlined, size: 18),
                label: Text('Horizontal'),
              ),
              ButtonSegment(
                value: TableOrientation.vertical,
                icon: Icon(Icons.view_column_outlined, size: 18),
                label: Text('Vertical'),
              ),
            ],
            selected: {section.defaultOrientation},
            onSelectionChanged: _mutating
                ? null
                : (s) => _setSectionOrientation(section, s.first),
          ),
          SegmentedButton<SeatingSide>(
            showSelectedIcon: false,
            segments: [
              for (final side in SeatingSide.values)
                ButtonSegment(
                  value: side,
                  label: Text(_seatingSideLabel(side, section.defaultOrientation)),
                ),
            ],
            selected: {section.defaultSeatingSide},
            onSelectionChanged:
                _mutating ? null : (s) => _setSectionSeatingSide(section, s.first),
          ),
        ],
      ],
    );
  }
}

class _LayoutConfig {
  const _LayoutConfig({
    required this.tableCount,
    required this.seatsPerTable,
    required this.rows,
    required this.orientation,
    required this.seatingSide,
  });
  final int tableCount;
  final int seatsPerTable;
  final int rows;
  final TableOrientation orientation;
  final SeatingSide seatingSide;
}

/// "How many tables, how many seats each, how many rows" — the whole floor
/// falls out of those three numbers. Capacity is shown, never typed: it is
/// tables x seats per table by definition, and a second editable field for it
/// could only ever disagree with the tables it describes.
class _ConfigureLayoutDialog extends StatefulWidget {
  const _ConfigureLayoutDialog({required this.section});
  final _Section section;

  @override
  State<_ConfigureLayoutDialog> createState() => _ConfigureLayoutDialogState();
}

class _ConfigureLayoutDialogState extends State<_ConfigureLayoutDialog> {
  late final TextEditingController _tables = TextEditingController(
      text: '${widget.section.tables.isEmpty ? 8 : widget.section.tables.length}');
  late final TextEditingController _seats =
      TextEditingController(text: '${widget.section.uniformSeatsPerTable ?? 6}');
  late int _rows = widget.section.gridRows;
  late TableOrientation _orientation = widget.section.defaultOrientation;
  late SeatingSide _seatingSide = widget.section.defaultSeatingSide;

  @override
  void dispose() {
    _tables.dispose();
    _seats.dispose();
    super.dispose();
  }

  int? get _tableCount => int.tryParse(_tables.text);
  int? get _seatsPerTable => int.tryParse(_seats.text);

  String? get _validationError {
    final t = _tableCount;
    final s = _seatsPerTable;
    if (t == null || t <= 0) return 'Enter how many tables this section has.';
    if (s == null || s <= 0) return 'Enter how many seats each table holds.';
    if (_rows > t) return 'Can\'t split $t table(s) across $_rows rows.';
    if (t > 200) return 'That\'s more than 200 tables — split it into sections instead.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _validationError;
    final t = _tableCount ?? 0;
    final s = _seatsPerTable ?? 0;
    final perRow = (_rows > 0 && t > 0) ? (t / _rows).ceil() : 0;

    return AlertDialog(
      title: Text('Layout for ${widget.section.name}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _tables,
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Number of tables'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _seats,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Seats per table'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Rows of tables'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: _rows <= 1 ? null : () => setState(() => _rows--),
                  ),
                  Text('$_rows', style: theme.textTheme.titleMedium),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: _rows >= t ? null : () => setState(() => _rows++),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedButton<TableOrientation>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: TableOrientation.horizontal,
                    icon: Icon(Icons.table_rows_outlined, size: 18),
                    label: Text('Horizontal'),
                  ),
                  ButtonSegment(
                    value: TableOrientation.vertical,
                    icon: Icon(Icons.view_column_outlined, size: 18),
                    label: Text('Vertical'),
                  ),
                ],
                selected: {_orientation},
                onSelectionChanged: (v) => setState(() => _orientation = v.first),
              ),
              const SizedBox(height: 8),
              SegmentedButton<SeatingSide>(
                showSelectedIcon: false,
                segments: [
                  for (final side in SeatingSide.values)
                    ButtonSegment(
                      value: side,
                      label: Text(_seatingSideLabel(side, _orientation)),
                    ),
                ],
                selected: {_seatingSide},
                onSelectionChanged: (v) => setState(() => _seatingSide = v.first),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: error != null
                    ? Text(error, style: TextStyle(color: theme.colorScheme.error))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Total capacity: $t × $s = ${t * s} seats',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$_rows row(s) of up to $perRow table(s), '
                            '${_orientation == TableOrientation.horizontal ? 'running horizontally' : 'running vertically'}.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
              ),
              if (error == null && t > 0) ...[
                const SizedBox(height: 12),
                Text('Preview', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: FloorLayoutView(
                      tables: _previewTables(t, s),
                      seatSize: 12,
                      scrollVertically: false,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: error != null
              ? null
              : () => Navigator.pop(
                    context,
                    _LayoutConfig(
                      tableCount: t,
                      seatsPerTable: s,
                      rows: _rows,
                      orientation: _orientation,
                      seatingSide: _seatingSide,
                    ),
                  ),
          child: const Text('Apply'),
        ),
      ],
    );
  }

  /// Throwaway in-memory tables, positioned exactly the way
  /// configure_section_layout() will position the real ones.
  List<FloorTable> _previewTables(int tableCount, int seatsPerTable) {
    final cols = (tableCount / _rows).ceil();
    return [
      for (var i = 0; i < tableCount; i++)
        FloorTable(
          id: 'preview-$i',
          tableNumber: i + 1,
          gridRow: i ~/ cols,
          gridCol: i % cols,
          orientation: _orientation,
          seatingSide: _seatingSide,
          seats: [
            for (var n = 1; n <= seatsPerTable; n++)
              FloorSeat(id: 'preview-$i-$n', seatNumber: n, status: FloorSeatStatus.available),
          ],
        ),
    ];
  }
}

class _HallRowsConfig {
  const _HallRowsConfig({required this.rowCount, required this.seatsPerRow});
  final int rowCount;
  final int seatsPerRow;
}

/// Guests seated in individual rows rather than around two-sided tables: row
/// 1 backs to the wall, pairs of rows face each other across a shared
/// serving aisle, and consecutive pairs sit back-to-back with no gap between
/// them. Row count and seats per row are the only inputs — the alternating
/// near/far facing and the aisle-vs-touching gap both fall out of a row's
/// position (even index vs. odd), matching configure_hall_rows() exactly.
class _ConfigureHallRowsDialog extends StatefulWidget {
  const _ConfigureHallRowsDialog({required this.section});
  final _Section section;

  @override
  State<_ConfigureHallRowsDialog> createState() => _ConfigureHallRowsDialogState();
}

class _ConfigureHallRowsDialogState extends State<_ConfigureHallRowsDialog> {
  late final TextEditingController _rows = TextEditingController(
      text: '${widget.section.tables.isEmpty ? 4 : widget.section.tables.length}');
  late final TextEditingController _seats =
      TextEditingController(text: '${widget.section.uniformSeatsPerTable ?? 10}');

  @override
  void dispose() {
    _rows.dispose();
    _seats.dispose();
    super.dispose();
  }

  int? get _rowCount => int.tryParse(_rows.text);
  int? get _seatsPerRow => int.tryParse(_seats.text);

  String? get _validationError {
    final r = _rowCount;
    final s = _seatsPerRow;
    if (r == null || r <= 0) return 'Enter how many rows this section has.';
    if (s == null || s <= 0) return 'Enter how many seats sit along each row.';
    if (r > 200) return 'That\'s more than 200 rows — split it into sections instead.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _validationError;
    final r = _rowCount ?? 0;
    final s = _seatsPerRow ?? 0;

    return AlertDialog(
      title: Text('Hall rows for ${widget.section.name}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Row 1 backs to the wall. Pairs of rows share a serving aisle; '
                'between one pair and the next, rows sit back-to-back.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _rows,
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Number of rows'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _seats,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Seats per row'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: error != null
                    ? Text(error, style: TextStyle(color: theme.colorScheme.error))
                    : Text(
                        'Total capacity: $r × $s = ${r * s} seats',
                        style: theme.textTheme.titleMedium,
                      ),
              ),
              if (error == null && r > 0) ...[
                const SizedBox(height: 12),
                Text('Preview', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                Builder(builder: (context) {
                  final preview = _previewRows(r, s);
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: SingleChildScrollView(
                      child: FloorLayoutView(
                        tables: preview,
                        seatSize: 12,
                        scrollVertically: false,
                        padding: EdgeInsets.zero,
                        showFacingLabels: true,
                        rowGap: (row) =>
                            _hallRowGap(preview.firstWhere((t) => t.gridRow == row)),
                      ),
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: error != null
              ? null
              : () => Navigator.pop(context, _HallRowsConfig(rowCount: r, seatsPerRow: s)),
          child: const Text('Apply'),
        ),
      ],
    );
  }

  /// Throwaway in-memory rows, positioned exactly the way
  /// configure_hall_rows() will position the real ones.
  List<FloorTable> _previewRows(int rowCount, int seatsPerRow) => [
        for (var i = 0; i < rowCount; i++)
          FloorTable(
            id: 'preview-$i',
            tableNumber: i + 1,
            gridRow: i,
            orientation: TableOrientation.horizontal,
            seatingSide: i.isEven ? SeatingSide.far : SeatingSide.near,
            seats: [
              for (var n = 1; n <= seatsPerRow; n++)
                FloorSeat(id: 'preview-$i-$n', seatNumber: n, status: FloorSeatStatus.available),
            ],
          ),
      ];
}
