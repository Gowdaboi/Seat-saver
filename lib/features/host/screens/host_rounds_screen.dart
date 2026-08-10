import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

class _Round {
  _Round({required this.id, required this.roundNumber, required this.status, this.startedAt});
  final String id;
  final int roundNumber;
  final String status;
  final DateTime? startedAt;
}

class _Seat {
  _Seat({
    required this.id,
    required this.seatNumber,
    required this.status,
    required this.tableNumber,
  });
  final String id;
  final int seatNumber;
  final String status;
  final int tableNumber;
}

/// Real round/seat-turnover management, branching on the event's
/// service_type per project-spec.md:
/// - Pankti: manually start each round (no smart timing in v1).
/// - Buffet: no rounds — mark a seat cleaning/available when a guest leaves.
class HostRoundsScreen extends StatefulWidget {
  const HostRoundsScreen({super.key});

  @override
  State<HostRoundsScreen> createState() => _HostRoundsScreenState();
}

class _HostRoundsScreenState extends State<HostRoundsScreen> {
  String? _eventId;
  final _contentKey = GlobalKey<_RoundsContentState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rounds'),
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
        builder: (context, eventId) => _RoundsContent(key: _contentKey, eventId: eventId),
      ),
    );
  }
}

class _RoundsContent extends StatefulWidget {
  const _RoundsContent({super.key, required this.eventId});
  final String eventId;

  @override
  State<_RoundsContent> createState() => _RoundsContentState();
}

class _RoundsContentState extends State<_RoundsContent> {
  String? _serviceType;
  List<_Round>? _rounds;
  List<_Seat>? _seats;
  String? _error;
  bool _mutating = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(covariant _RoundsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      _serviceType = null;
      _rounds = null;
      _seats = null;
      reload();
    }
  }

  Future<void> reload() async {
    setState(() => _error = null);
    try {
      final event = await supabase
          .from('events')
          .select('service_type')
          .eq('id', widget.eventId)
          .single();
      final serviceType = event['service_type'] as String;
      if (serviceType == 'pankti') {
        final rows = await supabase
            .from('rounds')
            .select('id, round_number, status, started_at')
            .eq('event_id', widget.eventId)
            .order('round_number');
        setState(() {
          _serviceType = serviceType;
          _rounds = List<Map<String, dynamic>>.from(rows)
              .map((r) => _Round(
                    id: r['id'] as String,
                    roundNumber: r['round_number'] as int,
                    status: r['status'] as String,
                    startedAt: r['started_at'] == null ? null : DateTime.parse(r['started_at'] as String),
                  ))
              .toList();
        });
      } else {
        final rows = await supabase
            .from('seats')
            .select('id, seat_number, status, tables!inner(table_number, event_id)')
            .eq('tables.event_id', widget.eventId);
        setState(() {
          _serviceType = serviceType;
          _seats = List<Map<String, dynamic>>.from(rows)
              .map((r) => _Seat(
                    id: r['id'] as String,
                    seatNumber: r['seat_number'] as int,
                    status: r['status'] as String,
                    tableNumber: (r['tables'] as Map)['table_number'] as int,
                  ))
              .toList()
            ..sort((a, b) {
              final byTable = a.tableNumber.compareTo(b.tableNumber);
              return byTable != 0 ? byTable : a.seatNumber.compareTo(b.seatNumber);
            });
        });
      }
    } catch (e) {
      setState(() => _error = 'Could not load: $e');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _startNextRound() async {
    setState(() => _mutating = true);
    try {
      final current = _rounds!.where((r) => r.status == 'current');
      for (final r in current) {
        await supabase.from('rounds').update({'status': 'completed'}).eq('id', r.id);
      }
      final nextNumber =
          _rounds!.isEmpty ? 1 : _rounds!.map((r) => r.roundNumber).reduce((a, b) => a > b ? a : b) + 1;
      final newRound = await supabase
          .from('rounds')
          .insert({
            'event_id': widget.eventId,
            'round_number': nextNumber,
            'status': 'current',
            'started_at': DateTime.now().toUtc().toIso8601String(),
          })
          .select('id')
          .single();

      // Guests book ahead of the round actually starting, so their booking
      // has no round yet. Starting round N is what says "everyone who's
      // confirmed but unseated is being seated for this round now" — that's
      // also what makes the no-show timeout apply to them (it's keyed off
      // rounds.started_at). See project-spec.md "Resolved decisions".
      await supabase
          .from('bookings')
          .update({'round_id': newRound['id']})
          .eq('event_id', widget.eventId)
          .eq('status', 'confirmed')
          .isFilter('round_id', null);

      await reload();
    } catch (e) {
      _showError('Could not start round: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _setSeatStatus(_Seat seat, String status) async {
    setState(() => _mutating = true);
    try {
      await supabase.from('seats').update({'status': status}).eq('id', seat.id);
      await reload();
    } catch (e) {
      _showError('Could not update seat: $e');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_serviceType == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _serviceType == 'pankti' ? _buildPankti() : _buildBuffet();
  }

  Widget _buildPankti() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _mutating ? null : _startNextRound,
            icon: const Icon(Icons.play_arrow),
            label: Text(_rounds!.isEmpty ? 'Start round 1' : 'Start round ${_rounds!.map((r) => r.roundNumber).reduce((a, b) => a > b ? a : b) + 1}'),
          ),
        ),
        Expanded(
          child: _rounds!.isEmpty
              ? const Center(child: Text('No rounds started yet.'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _rounds!.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    // most recent first
                    final round = _rounds!.reversed.toList()[i];
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          round.status == 'current'
                              ? Icons.play_circle_fill
                              : round.status == 'completed'
                                  ? Icons.check_circle_outline
                                  : Icons.schedule,
                          color: round.status == 'current' ? Colors.green : null,
                        ),
                        title: Text('Round ${round.roundNumber}'),
                        subtitle: Text(round.startedAt == null
                            ? round.status
                            : '${round.status} · started ${round.startedAt}'),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildBuffet() {
    if (_seats!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No seats designed for this event yet — add tables in Design floor first.'),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _seats!.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final seat = _seats![i];
        return Card(
          child: ListTile(
            title: Text('Table ${seat.tableNumber} · Seat ${seat.seatNumber}'),
            subtitle: Text(seat.status),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (seat.status == 'occupied')
                  TextButton(
                    onPressed: _mutating ? null : () => _setSeatStatus(seat, 'cleaning'),
                    child: const Text('Mark cleaning'),
                  ),
                if (seat.status == 'occupied' || seat.status == 'cleaning')
                  TextButton(
                    onPressed: _mutating ? null : () => _setSeatStatus(seat, 'available'),
                    child: const Text('Mark available'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
