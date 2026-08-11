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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await supabase
          .from('tables')
          .select(
              'id, table_number, grid_row, grid_col, orientation, seating_side, seats(id, seat_number, status)')
          .eq('section_id', widget.sectionId)
          .order('grid_row')
          .order('grid_col');
      setState(() {
        _tables = List<Map<String, dynamic>>.from(rows).map((t) {
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
        }).toList();
        _selected.removeWhere((id) => !_tables!.any((t) => t.seats.any((s) => s.id == id)));
      });
    } catch (e) {
      setState(() => _error = 'Could not load seats: $e');
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
                  onChanged: (v) => setState(() {
                    _partySize = v!;
                    _selected.clear();
                  }),
                ),
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
