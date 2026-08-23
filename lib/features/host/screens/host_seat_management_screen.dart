import 'package:flutter/material.dart';

import '../../../core/errors.dart';
import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

/// Reserved-but-not-physically-held. Deliberately not one of the four status
/// colours — this is a different axis (a claim on a seat) rather than a fifth
/// physical state.
const _reservedColor = Color(0xFF5C6BC0); // indigo

/// A seat spoken for by an active booking that the seat itself is not
/// currently holding.
///
/// This is what the seat grid had no way to show. Under the per-round model
/// (0014) a Pankti booking for a future sitting leaves `seats.status` alone —
/// the seat really is empty right now — so a host who had just assigned one
/// saw nothing change, and no amount of refreshing helped. The reservation
/// lives in bookings + booking_seats and has to be read from there.
class _Reservation {
  _Reservation({
    required this.bookingId,
    required this.guestName,
    required this.roundNumber,
    required this.roundStatus,
  });
  final String bookingId;
  final String? guestName;
  final int? roundNumber;
  final String? roundStatus;

  /// Whether this reservation still needs a marker of its own.
  ///
  /// Keyed off the seat's actual hold rather than off the round's status: if
  /// `current_booking_id` already points at this booking, the seat's colour
  /// is telling the story and a badge would just be noise. Anything else —
  /// a future sitting, or a booking into the running round whose seat could
  /// not be claimed because it was still occupied — has nothing else showing
  /// it, so it gets the badge.
  ///
  /// An earlier version asked "is the round upcoming?" instead, which hid
  /// exactly the case QA hit: a seat booked into the round already running,
  /// invisible on every screen.
  bool needsMarker(String? seatCurrentBookingId) =>
      roundStatus != 'completed' && seatCurrentBookingId != bookingId;
}

class _Seat {
  _Seat({
    required this.id,
    required this.seatNumber,
    required this.status,
    required this.tableNumber,
    required this.sectionName,
    this.currentBookingId,
    this.reservation,
  });
  final String id;
  final int seatNumber;
  final String status;
  final int tableNumber;
  final String sectionName;
  final String? currentBookingId;
  final _Reservation? reservation;

  bool get isReservedElsewhere => reservation?.needsMarker(currentBookingId) ?? false;
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

/// A sitting the host can put a walk-in into.
class _RoundOption {
  _RoundOption({required this.id, required this.number, required this.status});
  final String id;
  final int number;
  final String status;

  String get label => status == 'current' ? 'Round $number (running)' : 'Round $number';
}

class _SeatManagementContentState extends State<_SeatManagementContent> {
  List<_Seat>? _seats;

  /// Rounds still open to bookings. Empty for buffet, which has none.
  List<_RoundOption> _rounds = const [];
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
          .select('id, seat_number, status, current_booking_id, '
              'tables!inner(table_number, event_id, sections(name))')
          .eq('tables.event_id', widget.eventId);

      // Read in two steps rather than one deeply nested embed: the join that
      // matters here is booking_seats -> bookings -> (guests, rounds), and
      // filtering an embedded resource three levels down is exactly where
      // PostgREST queries get fragile.
      final bookingRows = await supabase
          .from('bookings')
          .select('id, status, guests(name), rounds(round_number, status)')
          .eq('event_id', widget.eventId)
          .inFilter('status', ['requested', 'confirmed']);

      final byBookingId = <String, _Reservation>{};
      for (final b in List<Map<String, dynamic>>.from(bookingRows)) {
        final round = b['rounds'] as Map?;
        byBookingId[b['id'] as String] = _Reservation(
          bookingId: b['id'] as String,
          guestName: (b['guests'] as Map?)?['name'] as String?,
          roundNumber: round?['round_number'] as int?,
          // Buffet has no round at all; treat that as "not a future
          // reservation", since there the seat status is the reservation.
          roundStatus: round?['status'] as String?,
        );
      }

      // Offered in the assign dialog so a host can deliberately seat someone
      // in a later sitting. host_assign_seats otherwise always takes the
      // earliest round with room, which makes "put this family in the second
      // sitting" impossible to express.
      final roundRows = await supabase
          .from('rounds')
          .select('id, round_number, status')
          .eq('event_id', widget.eventId)
          .inFilter('status', ['upcoming', 'current'])
          .order('round_number');

      final bySeatId = <String, _Reservation>{};
      if (byBookingId.isNotEmpty) {
        final links = await supabase
            .from('booking_seats')
            .select('seat_id, booking_id')
            .inFilter('booking_id', byBookingId.keys.toList());
        for (final link in List<Map<String, dynamic>>.from(links)) {
          final reservation = byBookingId[link['booking_id'] as String];
          if (reservation != null) bySeatId[link['seat_id'] as String] = reservation;
        }
      }

      setState(() {
        _rounds = List<Map<String, dynamic>>.from(roundRows)
            .map((r) => _RoundOption(
                  id: r['id'] as String,
                  number: r['round_number'] as int,
                  status: r['status'] as String,
                ))
            .toList();
        _seats = List<Map<String, dynamic>>.from(rows).map((r) {
          final t = r['tables'] as Map;
          final id = r['id'] as String;
          return _Seat(
            id: id,
            seatNumber: r['seat_number'] as int,
            status: r['status'] as String,
            tableNumber: t['table_number'] as int,
            sectionName: (t['sections'] as Map?)?['name'] as String? ?? '—',
            currentBookingId: r['current_booking_id'] as String?,
            reservation: bySeatId[id],
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
      _showError(friendlyError(e, fallback: 'Could not update the seat.'));
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  int get _reservedCount =>
      (_seats ?? const <_Seat>[]).where((s) => s.isReservedElsewhere).length;

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
    // null = let the RPC choose the earliest round with room, which is the
    // right default and what happened unconditionally before.
    String? roundId;
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
              if (_rounds.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: roundId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Sitting'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Next with room'),
                    ),
                    for (final round in _rounds)
                      DropdownMenuItem<String?>(
                        value: round.id,
                        child: Text(round.label),
                      ),
                  ],
                  onChanged: (v) => setDialogState(() => roundId = v),
                ),
                const SizedBox(height: 8),
                Text(
                  'Leave as "Next with room" unless this guest has to be in a '
                  'particular sitting — a new round is opened automatically when '
                  'the planned ones fill up.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
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

    final seatCount = _selected.length;
    setState(() => _mutating = true);
    try {
      final bookingId = await supabase.rpc('host_assign_seats', params: {
        'p_event_id': widget.eventId,
        'p_seat_ids': _selected.toList(),
        'p_party_size': seatCount,
        'p_guest_name': name,
        'p_guest_phone': phone.isEmpty ? null : phone,
        // Null lets the RPC pick the earliest round with room, opening the
        // next sitting when the planned ones are full. A value here is the
        // host overriding that deliberately.
        'p_round_id': roundId,
      }) as String;
      setState(() {
        _selected.clear();
        _selectMode = false;
      });
      await reload();

      // Which round it landed in is the host's main question — the RPC
      // chooses it, so telling them afterwards is the only way they find out.
      final round = await supabase
          .from('bookings')
          .select('rounds(round_number)')
          .eq('id', bookingId)
          .maybeSingle();
      final roundNumber = (round?['rounds'] as Map?)?['round_number'] as int?;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            roundNumber == null
                ? '$name booked into $seatCount seat(s).'
                : '$name booked into $seatCount seat(s) for Round $roundNumber.',
          ),
        ),
      );
    } catch (e) {
      // Was dumping the whole PostgrestException — constraint name, key
      // tuple and all — into the snackbar.
      _showError(friendlyError(e, fallback: 'Could not assign the seat(s).'));
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
            if (_reservedCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: _reservedColor, width: 2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$_reservedCount seat(s) are reserved but not yet held — booked '
                        'for a round that has not started. They stay available until '
                        'that round begins.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
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
    final reservation = seat.reservation;
    final reservedAhead = seat.isReservedElsewhere;
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

    // A seat held for a sitting that hasn't started is physically empty, so
    // its status says 'available' and always will until start_round() runs.
    // Without this marker the host assigns a seat and sees nothing change —
    // which reads as "the booking failed" and invites double-booking.
    if (reservedAhead && reservation != null) {
      final who = reservation.guestName ?? 'a guest';
      tooltip = 'Reserved for Round ${reservation.roundNumber ?? '?'} — $who'
          '${_selectMode ? '\nStill selectable: a seat can be booked for a different round.' : ''}';
    }

    final scheme = Theme.of(context).colorScheme;
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
            color: color ?? scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: selected
                ? Border.all(color: scheme.primary, width: 2)
                : reservedAhead
                    ? Border.all(color: _reservedColor, width: 2)
                    : null,
          ),
          child: reservedAhead
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${seat.seatNumber}'),
                    Text(
                      'R${reservation?.roundNumber ?? '?'}',
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.1,
                        fontWeight: FontWeight.w600,
                        color: _reservedColor,
                      ),
                    ),
                  ],
                )
              : Text('${seat.seatNumber}'),
        ),
      ),
    );
  }
}
