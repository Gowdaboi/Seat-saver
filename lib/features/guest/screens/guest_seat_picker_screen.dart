import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_client.dart';
import '../../shared/widgets/floor_layout.dart';

/// Real seat picker: fetches this section's tables/seats, lets the guest
/// select exactly partySize available seats, then books them atomically via
/// the book_seats() RPC (see supabase/migrations/0005_guest_booking.sql —
/// guests have no direct RLS write access to `seats`, so this has to be a
/// security-definer function, not a client-side insert/update).
///
/// Seats are drawn in the host's actual arrangement via FloorLayoutView, the
/// same renderer the host designs with, so the guest is picking off a picture
/// of the room rather than a flat list of tables.
class GuestSeatPickerScreen extends StatefulWidget {
  const GuestSeatPickerScreen({super.key, required this.eventId, required this.sectionId});
  final String eventId;
  final String sectionId;

  @override
  State<GuestSeatPickerScreen> createState() => _GuestSeatPickerScreenState();
}

class _GuestSeatPickerScreenState extends State<GuestSeatPickerScreen> {
  int _partySize = 2;
  final Set<String> _selected = {};
  List<FloorTable>? _tables;
  String? _error;
  bool _booking = false;

  /// The sitting these seats belong to. Null for buffet, which has no
  /// rounds. Resolved by ensure_bookable_round, which hands back the
  /// earliest round with room for this party and opens a new sitting when
  /// the planned ones are full.
  String? _roundId;
  int? _roundNumber;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      // Which round depends on party size, so this is resolved on every
      // load rather than once — a party of 6 may not fit where a pair does.
      final roundId = await supabase.rpc('ensure_bookable_round', params: {
        'p_event_id': widget.eventId,
        'p_party_size': _partySize,
      }) as String?;

      int? roundNumber;
      if (roundId != null) {
        // Via an RPC because `rounds` is scoped to the caterer and to guests
        // who already hold a booking (0022) — and this guest is in the middle
        // of making their first one.
        roundNumber = await supabase.rpc(
          'public_round_number',
          params: {'p_round_id': roundId},
        ) as int?;
      }

      // seats_for_round, not a select on `seats`: whether a seat is free is
      // a question about this round's bookings, which the seat row alone
      // cannot answer now that the same seat serves several sittings.
      final rows = await supabase.rpc('seats_for_round', params: {
        'p_section_id': widget.sectionId,
        'p_round_id': roundId,
      });

      final byTable = <String, List<Map<String, dynamic>>>{};
      for (final row in List<Map<String, dynamic>>.from(rows)) {
        byTable.putIfAbsent(row['table_id'] as String, () => []).add(row);
      }

      if (!mounted) return;
      setState(() {
        _roundId = roundId;
        _roundNumber = roundNumber;
        _tables = byTable.entries.map((entry) {
          final first = entry.value.first;
          final seats = entry.value
              .map((s) => FloorSeat(
                    id: s['seat_id'] as String,
                    seatNumber: s['seat_number'] as int,
                    // Free for *this round* is what the guest can pick.
                    // Anything else renders as taken, whatever the seat is
                    // physically doing right now.
                    status: (s['is_free'] as bool)
                        ? FloorSeatStatus.available
                        : FloorSeatStatus.booked,
                  ))
              .toList()
            ..sort((a, b) => a.seatNumber.compareTo(b.seatNumber));
          return FloorTable(
            id: entry.key,
            tableNumber: first['table_number'] as int,
            gridRow: first['grid_row'] as int,
            gridCol: first['grid_col'] as int,
            orientation: orientationFromString(first['orientation'] as String?),
            seatingSide: seatingSideFromString(first['seating_side'] as String?),
            seats: seats,
          );
        }).toList()
          ..sort((a, b) {
            final byRow = a.gridRow.compareTo(b.gridRow);
            return byRow != 0 ? byRow : a.gridCol.compareTo(b.gridCol);
          });
        _selected.removeWhere((id) => !_tables!.any((t) => t.seats.any((s) => s.id == id)));
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load seats: $e');
    }
  }

  void _toggle(String seatId) {
    setState(() {
      if (_selected.contains(seatId)) {
        _selected.remove(seatId);
      } else if (_selected.length < _partySize) {
        _selected.add(seatId);
      }
    });
  }

  Future<void> _book() async {
    setState(() => _booking = true);
    try {
      final bookingId = await supabase.rpc('book_seats', params: {
        'p_event_id': widget.eventId,
        'p_seat_ids': _selected.toList(),
        'p_party_size': _partySize,
        // Pinned to the round the guest was actually shown, so a round
        // filling up between load and tap fails loudly instead of quietly
        // booking them into a different sitting.
        'p_round_id': _roundId,
      }) as String;
      if (mounted) {
        context.push('/e/${widget.eventId}/confirmation?booking=$bookingId');
      }
    } on PostgrestException catch (e) {
      // most likely: a seat got taken by someone else, or one booking per
      // guest per event was already used up — either way, refresh so the
      // guest sees current reality rather than stale selections.
      await _load();
      if (mounted) {
        setState(() => _selected.clear());
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not book: $e')));
      }
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick your seats'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Text('Party size:'),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: _partySize,
                  items: [for (var i = 1; i <= 6; i++) DropdownMenuItem(value: i, child: Text('$i'))],
                  // Reloads, because party size decides which round has room
                  // — and therefore which seats are free to show.
                  onChanged: (v) {
                    setState(() {
                      _partySize = v!;
                      _selected.clear();
                    });
                    _load();
                  },
                ),
                if (_roundNumber != null) ...[
                  const Spacer(),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('Round $_roundNumber'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : _tables == null
              ? const Center(child: CircularProgressIndicator())
              : FloorLayoutView(
                  tables: _tables!,
                  selectedSeatIds: _selected,
                  partySize: _partySize,
                  onToggleSeat: _toggle,
                ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const FloorLegend(),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selected.length == _partySize && !_booking ? _book : null,
                  child: _booking
                      ? const SizedBox(
                          height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text('Book ${_selected.length}/$_partySize seats'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
