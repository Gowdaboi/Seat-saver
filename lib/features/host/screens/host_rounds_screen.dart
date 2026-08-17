import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

/// How often the board re-reads seat state on its own. Seats change from the
/// scan screen and from guests booking, so a board left open on the pass
/// would otherwise drift out of date without the host knowing.
const _autoRefreshEvery = Duration(seconds: 30);

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
    required this.tableId,
    required this.tableNumber,
    required this.currentBookingId,
  });
  final String id;
  final int seatNumber;
  final String status;
  final String tableId;
  final int tableNumber;

  /// Who currently holds the seat. Freeing a seat has to clear this, not
  /// just the status — see the release/replay note in project-spec.md.
  final String? currentBookingId;
}

/// Real round/seat-turnover management, branching on the event's
/// service_type per project-spec.md:
/// - Pankti: manually start each round (no smart timing in v1).
/// - Buffet: no rounds — seats simply turn over as guests come and go.
///
/// Both service types get the seat board: Pankti turns seats over *between*
/// rounds, which is exactly when the host is working from this screen.
class HostRoundsScreen extends StatelessWidget {
  const HostRoundsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rounds')),
      // Refresh lives in the summary bar next to the freshness label rather
      // than in the app bar, so the control and the "updated Ns ago" it
      // affects sit together.
      body: EventPicker(
        builder: (context, eventId) => _RoundsContent(eventId: eventId),
      ),
    );
  }
}

class _RoundsContent extends StatefulWidget {
  const _RoundsContent({required this.eventId});
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

  String _statusFilter = 'all';
  DateTime? _lastSync;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    reload();
    // One timer drives both the "updated Ns ago" label and the periodic
    // re-read, so the label can never claim data is fresher than it is.
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final stale = _lastSync == null ||
          DateTime.now().difference(_lastSync!) >= _autoRefreshEvery;
      if (stale && !_mutating) {
        reload();
      } else {
        setState(() {});
      }
    });
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

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
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

      final seatRows = await supabase
          .from('seats')
          .select('id, seat_number, status, current_booking_id, tables!inner(id, table_number, event_id)')
          .eq('tables.event_id', widget.eventId);

      List<_Round> rounds = const [];
      if (serviceType == 'pankti') {
        final roundRows = await supabase
            .from('rounds')
            .select('id, round_number, status, started_at')
            .eq('event_id', widget.eventId)
            .order('round_number');
        rounds = List<Map<String, dynamic>>.from(roundRows)
            .map((r) => _Round(
                  id: r['id'] as String,
                  roundNumber: r['round_number'] as int,
                  status: r['status'] as String,
                  startedAt:
                      r['started_at'] == null ? null : DateTime.parse(r['started_at'] as String),
                ))
            .toList();
      }

      if (!mounted) return;
      setState(() {
        _serviceType = serviceType;
        _rounds = rounds;
        _seats = List<Map<String, dynamic>>.from(seatRows).map((r) {
          final table = r['tables'] as Map;
          return _Seat(
            id: r['id'] as String,
            seatNumber: r['seat_number'] as int,
            status: r['status'] as String,
            tableId: table['id'] as String,
            tableNumber: table['table_number'] as int,
            currentBookingId: r['current_booking_id'] as String?,
          );
        }).toList()
          ..sort((a, b) {
            final byTable = a.tableNumber.compareTo(b.tableNumber);
            return byTable != 0 ? byTable : a.seatNumber.compareTo(b.seatNumber);
          });
        _lastSync = DateTime.now();
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load: $e');
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

  Future<void> _startNextRound() => _mutate('Could not start round', () async {
        final current = _rounds!.where((r) => r.status == 'current');
        for (final r in current) {
          await supabase.from('rounds').update({'status': 'completed'}).eq('id', r.id);
        }
        final nextNumber = _rounds!.isEmpty
            ? 1
            : _rounds!.map((r) => r.roundNumber).reduce((a, b) => a > b ? a : b) + 1;
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
      });

  /// Returning a seat to 'available' releases its ownership as well as its
  /// status: current_booking_id is what check_in_booking() tests to decide
  /// whether a scanned QR still holds the seat, so leaving it set lets the
  /// previous guest re-scan an old QR and retake a seat the host just freed.
  Map<String, dynamic> _statusPatch(String status) => {
        'status': status,
        if (status == 'available') 'current_booking_id': null,
      };

  Future<void> _setSeatStatus(_Seat seat, String status) =>
      _mutate('Could not update seat', () async {
        await supabase.from('seats').update(_statusPatch(status)).eq('id', seat.id);
      });

  Future<void> _setTableStatus(
    int tableNumber,
    String status, {
    required Set<String> fromStatuses,
  }) =>
      _mutate('Could not update table', () async {
        final ids = _seatsForTable(tableNumber)
            .where((s) => fromStatuses.contains(s.status))
            .map((s) => s.id)
            .toList();
        if (ids.isEmpty) return;
        await supabase.from('seats').update(_statusPatch(status)).inFilter('id', ids);
      });

  // ── derived state ─────────────────────────────────────────────────────

  List<_Seat> get _allSeats => _seats ?? const [];

  List<int> get _tableNumbers =>
      _allSeats.map((s) => s.tableNumber).toSet().toList()..sort();

  List<_Seat> _seatsForTable(int tableNumber) =>
      _allSeats.where((s) => s.tableNumber == tableNumber).toList();

  int _countOf(String status) => _allSeats.where((s) => s.status == status).length;

  bool _matchesFilter(_Seat seat) => _statusFilter == 'all' || seat.status == _statusFilter;

  // ── build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_serviceType == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        _summaryBar(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              if (_serviceType == 'pankti') ...[
                _roundControls(),
                const SizedBox(height: 16),
              ],
              if (_allSeats.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: Text(
                      'No seats designed for this event yet — add tables in Design floor first.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              else ...[
                _filterPills(),
                const SizedBox(height: 12),
                for (final tableNumber in _tableNumbers) _tableCard(tableNumber),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String get _syncLabel {
    if (_lastSync == null) return 'Syncing…';
    final seconds = DateTime.now().difference(_lastSync!).inSeconds;
    if (seconds < 5) return 'Updated just now';
    if (seconds < 60) return 'Updated ${seconds}s ago';
    final minutes = seconds ~/ 60;
    return 'Updated ${minutes}m ago';
  }

  Widget _summaryBar() {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _metric('Total', _allSeats.length, null),
                        _metric('Occupied', _countOf('occupied'), _statusColor('occupied')),
                        _metric('Available', _countOf('available'), _statusColor('available')),
                        _metric('Cleaning', _countOf('cleaning'), _statusColor('cleaning')),
                      ],
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_syncLabel, style: theme.textTheme.bodySmall),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh now',
                      onPressed: _mutating ? null : reload,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, int value, Color? color) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (color != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Text('$value', style: theme.textTheme.titleMedium),
            ],
          ),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _roundControls() {
    final rounds = _rounds ?? const <_Round>[];
    final nextNumber =
        rounds.isEmpty ? 1 : rounds.map((r) => r.roundNumber).reduce((a, b) => a > b ? a : b) + 1;
    final current = rounds.where((r) => r.status == 'current').toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    current.isEmpty
                        ? 'No round running'
                        : 'Round ${current.first.roundNumber} running',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.icon(
                  onPressed: _mutating ? null : _startNextRound,
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Start round $nextNumber'),
                ),
              ],
            ),
            if (rounds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final round in rounds.reversed)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        round.status == 'current'
                            ? Icons.play_circle_fill
                            : round.status == 'completed'
                                ? Icons.check_circle_outline
                                : Icons.schedule,
                        size: 16,
                        color: round.status == 'current' ? Colors.green : null,
                      ),
                      label: Text('Round ${round.roundNumber}'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filterPills() {
    const options = {
      'all': 'All',
      'available': 'Available',
      'cleaning': 'Needs cleaning',
      'occupied': 'Occupied',
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final entry in options.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(entry.key == 'all'
                    ? entry.value
                    : '${entry.value} (${_countOf(entry.key)})'),
                selected: _statusFilter == entry.key,
                onSelected: (_) => setState(() => _statusFilter = entry.key),
              ),
            ),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case 'available':
        return const Color(0xFF7CB342); // soft green
      case 'occupied':
        return const Color(0xFFE57373); // soft red
      case 'cleaning':
        return const Color(0xFFFFB74D); // soft amber
      default:
        return scheme.outlineVariant; // blocked
    }
  }

  Widget _tableCard(int tableNumber) {
    final seats = _seatsForTable(tableNumber);
    final visible = seats.where(_matchesFilter).toList();
    // A filter that excludes the whole table hides the card, so the board
    // shows only what the host asked to see.
    if (visible.isEmpty && _statusFilter != 'all') return const SizedBox.shrink();

    final occupied = seats.where((s) => s.status == 'occupied').length;
    final cleaning = seats.where((s) => s.status == 'cleaning').length;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Table $tableNumber', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Text(
                  '$occupied/${seats.length} occupied'
                  '${cleaning > 0 ? ' · $cleaning cleaning' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  enabled: !_mutating,
                  tooltip: 'Table actions',
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (choice) {
                    switch (choice) {
                      // Everything except blocked seats goes back to
                      // available — the "reset this table" action.
                      case 'all_available':
                        _setTableStatus(tableNumber, 'available',
                            fromStatuses: {'available', 'occupied', 'cleaning'});
                      // The party just left: flag their seats for cleaning
                      // without touching seats nobody was sitting in.
                      case 'all_cleaning':
                        _setTableStatus(tableNumber, 'cleaning', fromStatuses: {'occupied'});
                      // Cleaning finished / guests gone: put the seats that
                      // were in use back into service, leaving blocked ones.
                      case 'clear':
                        _setTableStatus(tableNumber, 'available',
                            fromStatuses: {'occupied', 'cleaning'});
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'all_available', child: Text('Mark all available')),
                    PopupMenuItem(value: 'all_cleaning', child: Text('Mark table for cleaning')),
                    PopupMenuItem(value: 'clear', child: Text('Clear table')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final seat in seats) _seatNode(seat)],
            ),
          ],
        ),
      ),
    );
  }

  /// A seat node. Tap opens the status controls; a horizontal drag is the
  /// quick path — right for available, left for cleaning — which works in a
  /// grid where a Dismissible row would not.
  Widget _seatNode(_Seat seat) {
    final color = _statusColor(seat.status);
    final dimmed = !_matchesFilter(seat);

    return Opacity(
      opacity: dimmed ? 0.25 : 1,
      child: GestureDetector(
        onHorizontalDragEnd: _mutating || seat.status == 'blocked'
            ? null
            : (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity > 0 && seat.status != 'available') {
                  _setSeatStatus(seat, 'available');
                } else if (velocity < 0 && seat.status != 'cleaning') {
                  _setSeatStatus(seat, 'cleaning');
                }
              },
        child: Tooltip(
          message: 'Seat ${seat.seatNumber} · ${seat.status}',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _mutating ? null : () => _showSeatActions(seat),
            child: Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.25),
                border: Border.all(color: color, width: 1.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${seat.seatNumber}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSeatActions(_Seat seat) async {
    final status = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Table ${seat.tableNumber} · Seat ${seat.seatNumber}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text('Currently ${seat.status}',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: 'occupied',
                    icon: Icon(Icons.person, size: 18),
                    label: Text('Occupied'),
                  ),
                  ButtonSegment(
                    value: 'cleaning',
                    icon: Icon(Icons.cleaning_services_outlined, size: 18),
                    label: Text('Cleaning'),
                  ),
                  ButtonSegment(
                    value: 'available',
                    icon: Icon(Icons.check_circle_outline, size: 18),
                    label: Text('Available'),
                  ),
                ],
                selected: {seat.status},
                onSelectionChanged: (v) => Navigator.pop(context, v.first),
              ),
            ],
          ),
        ),
      ),
    );
    if (status != null && status != seat.status) {
      await _setSeatStatus(seat, status);
    }
  }
}
