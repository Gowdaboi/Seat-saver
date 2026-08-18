import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

class _Seat {
  _Seat({
    required this.id,
    required this.seatNumber,
    required this.status,
    required this.tableNumber,
    required this.sectionName,
  });
  final String id;
  final int seatNumber;
  final String status;
  final int tableNumber;
  final String sectionName;
}

/// "Manually block/assign seats (walk-ins, VIP holds, guests without the
/// app)" — a host capability named in the original spec but never built
/// until now. Blocking is a plain status update (hosts already have RLS
/// write access to seats); assigning creates a guest record on the fly
/// (walk-ins have no phone-OTP account) via host_assign_seats()
/// (0008_host_seat_assignment.sql).
class HostSeatManagementScreen extends StatefulWidget {
  const HostSeatManagementScreen({super.key});

  @override
  State<HostSeatManagementScreen> createState() => _HostSeatManagementScreenState();
}

class _HostSeatManagementScreenState extends State<HostSeatManagementScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage seats')),
      body: EventPicker(
        builder: (context, eventId) => _SeatManagementContent(key: ValueKey(eventId), eventId: eventId),
      ),
    );
  }
}

class _SeatManagementContent extends StatefulWidget {
  const _SeatManagementContent({super.key, required this.eventId});
  final String eventId;

  @override
  State<_SeatManagementContent> createState() => _SeatManagementContentState();
}

class _SeatManagementContentState extends State<_SeatManagementContent> {
  List<_Seat>? _seats;
  String? _error;
  bool _mutating = false;
  bool _selectMode = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() => _error = null);
    try {
      final rows = await supabase
          .from('seats')
          .select('id, seat_number, status, tables!inner(table_number, event_id, sections(name))')
          .eq('tables.event_id', widget.eventId);
      setState(() {
        _seats = List<Map<String, dynamic>>.from(rows).map((r) {
          final t = r['tables'] as Map;
          return _Seat(
            id: r['id'] as String,
            seatNumber: r['seat_number'] as int,
            status: r['status'] as String,
            tableNumber: t['table_number'] as int,
            sectionName: (t['sections'] as Map?)?['name'] as String? ?? '—',
          );
        }).toList()
          ..sort((a, b) {
            final bySection = a.sectionName.compareTo(b.sectionName);
            if (bySection != 0) return bySection;
            final byTable = a.tableNumber.compareTo(b.tableNumber);
            return byTable != 0 ? byTable : a.seatNumber.compareTo(b.seatNumber);
          });
      });
    } catch (e) {
      setState(() => _error = 'Could not load seats: $e');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Returning a seat to 'available' has to release its ownership too, not
  /// just its status. current_booking_id is what check_in_booking() tests to
  /// decide whether a scanned QR still legitimately holds the seat (0007) —
  /// leaving it set on a freed seat lets the previous guest re-scan their old
  /// QR and flip it straight back to occupied, which on a Buffet event has no
  /// round check to stop it. That is the exact replay 0007 exists to prevent.
  Future<void> _setStatus(_Seat seat, String status) async {
    setState(() => _mutating = true);
    try {
      await supabase.from('seats').update({
        'status': status,
        if (status == 'available') 'current_booking_id': null,
      }).eq('id', seat.id);
      await reload();
    } catch (e) {
      _showError('Could not update seat: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  void _toggleSelect(String seatId) {
    setState(() {
      if (_selected.contains(seatId)) {
        _selected.remove(seatId);
      } else {
        _selected.add(seatId);
      }
    });
  }

  Future<void> _showAssignDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    // No "seat them now" toggle: assigning a seat makes a booking, and
    // whether the guest is actually sitting down is what check-in decides.
    // Letting the host set both independently let the two drift apart.
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Assign ${_selected.length} seat(s)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Guest name'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                  hintText: 'Leave blank if unknown',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Assign')),
          ],
        ),
      ),
    );
    final name = nameController.text.trim();
    final phone = phoneController.text.trim();
    nameController.dispose();
    phoneController.dispose();
    if (result != true) return;
    if (name.isEmpty) {
      // Previously this returned silently: the dialog closed, nothing was
      // assigned, and the host got no indication why.
      _showError('Enter a guest name to assign the seat(s).');
      return;
    }

    setState(() => _mutating = true);
    try {
      await supabase.rpc('host_assign_seats', params: {
        'p_event_id': widget.eventId,
        'p_seat_ids': _selected.toList(),
        'p_party_size': _selected.length,
        'p_guest_name': name,
        'p_guest_phone': phone.isEmpty ? null : phone,
        // p_round_id omitted: the RPC picks the earliest round with room,
        // creating the next sitting when the planned ones are full.
      });
      setState(() {
        _selected.clear();
        _selectMode = false;
      });
      await reload();
    } catch (e) {
      _showError('Could not assign seat(s): $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_seats == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_seats!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No seats designed for this event yet — add tables in Design floor first.'),
        ),
      );
    }

    final bySection = <String, Map<int, List<_Seat>>>{};
    for (final seat in _seats!) {
      bySection.putIfAbsent(seat.sectionName, () => {}).putIfAbsent(seat.tableNumber, () => []).add(seat);
    }

    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _selectMode
                          ? 'Tap available seats to select, then Assign'
                          : 'Tap a seat to block/unblock it, or Select seats to assign a walk-in/VIP',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _mutating
                        ? null
                        : () => setState(() {
                              _selectMode = !_selectMode;
                              _selected.clear();
                            }),
                    child: Text(_selectMode ? 'Cancel' : 'Select seats'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                children: [
                  for (final sectionEntry in bySection.entries) ...[
                    Text(sectionEntry.key, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final tableEntry in sectionEntry.value.entries) ...[
                      Text('Table ${tableEntry.key}', style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [for (final seat in tableEntry.value) _seatChip(seat)],
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
        if (_selectMode && _selected.isNotEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: FilledButton(
              onPressed: _mutating ? null : _showAssignDialog,
              child: Text('Assign ${_selected.length} seat(s)'),
            ),
          ),
      ],
    );
  }

  Widget _seatChip(_Seat seat) {
    final selected = _selected.contains(seat.id);
    Color? color;
    VoidCallback? onTap;
    String tooltip = seat.status;

    switch (seat.status) {
      case 'available':
        color = selected ? Theme.of(context).colorScheme.primary : null;
        // Only selectable now. Blocking was removed in 0014 — a seat that is
        // permanently out of service is a floor-plan fact, so it is deleted
        // in Design floor rather than toggled here mid-shift.
        onTap = _selectMode && !_mutating ? () => _toggleSelect(seat.id) : null;
        tooltip = _selectMode ? 'Tap to select' : 'Available';
        break;
      case 'booked':
        color = Colors.amber.shade200;
        onTap = _mutating ? null : () => _setStatus(seat, 'occupied');
        tooltip = 'Tap to mark occupied';
        break;
      case 'occupied':
        // Buffet seats get reused within one event — guest eats, leaves, the
        // seat is cleared and rebooked. Without this step 'occupied' is a
        // dead end and that reuse (which 0007 rewrote the double-booking
        // trigger to allow) can't actually be reached from the app.
        color = Colors.red.shade200;
        onTap = _mutating ? null : () => _setStatus(seat, 'cleaning');
        tooltip = 'Tap to clear the seat (guest has left)';
        break;
      case 'cleaning':
        color = Colors.orange.shade200;
        onTap = _mutating ? null : () => _setStatus(seat, 'available');
        tooltip = 'Tap to mark available';
        break;
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color ?? Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: selected ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2) : null,
          ),
          child: Text('${seat.seatNumber}'),
        ),
      ),
    );
  }
}
