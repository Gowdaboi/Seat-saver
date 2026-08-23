import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/errors.dart';
import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

/// How often the board re-reads seat state on its own. Seats change from the
/// scan screen and from guests booking, so a board left open on the pass
/// would otherwise drift out of date without the host knowing.
const _autoRefreshEvery = Duration(seconds: 30);

class _Round {
  _Round({
    required this.id,
    required this.roundNumber,
    required this.status,
    this.startedAt,
    this.scheduledStartAt,
  });
  final String id;
  final int roundNumber;
  final String status;
  final DateTime? startedAt;

  /// When this round is *planned* to start, as opposed to startedAt, which
  /// is stamped when the host actually presses Start. Reminders count back
  /// from this, so a round without one simply never sends any (0015).
  final DateTime? scheduledStartAt;
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

/// Who is sitting in an occupied seat, reached through the seat's
/// current_booking_id.
class _Occupant {
  _Occupant({
    required this.bookingId,
    required this.guestId,
    required this.name,
    required this.phone,
    required this.partySize,
    required this.bookingStatus,
    required this.isVip,
  });
  final String bookingId;
  final String guestId;
  final String? name;
  final String? phone;
  final int partySize;
  final String bookingStatus;
  final bool isVip;
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
  int _reminderLeadMinutes = 5;
  String _reminderChannel = 'sms';

  /// Provider template id. Null means "send composed text", which carriers
  /// reject for business-initiated WhatsApp and for SMS to India — so for a
  /// caterer operating there this is the field that decides whether
  /// reminders work at all, and it had no UI.
  String? _reminderContentSid;
  List<_Round>? _rounds;

  /// Seats spoken for per round id. The five status metrics count physical
  /// state, and a booking for a future sitting has none — so without this the
  /// board reads 0 booked however many guests are expected, which is exactly
  /// what a host assigning seats before service sees.
  Map<String, int> _reservedByRound = const {};
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
          .select('service_type, reminder_lead_minutes, reminder_channel, reminder_content_sid')
          .eq('id', widget.eventId)
          .single();
      final serviceType = event['service_type'] as String;
      final reminderLead = event['reminder_lead_minutes'] as int;
      final reminderChannel = event['reminder_channel'] as String;
      final reminderContentSid = event['reminder_content_sid'] as String?;

      final seatRows = await supabase
          .from('seats')
          .select('id, seat_number, status, current_booking_id, tables!inner(id, table_number, event_id)')
          .eq('tables.event_id', widget.eventId);

      List<_Round> rounds = const [];
      if (serviceType == 'pankti') {
        final roundRows = await supabase
            .from('rounds')
            .select('id, round_number, status, started_at, scheduled_start_at')
            .eq('event_id', widget.eventId)
            .order('round_number');
        rounds = List<Map<String, dynamic>>.from(roundRows)
            .map((r) => _Round(
                  id: r['id'] as String,
                  roundNumber: r['round_number'] as int,
                  status: r['status'] as String,
                  startedAt:
                      r['started_at'] == null ? null : DateTime.parse(r['started_at'] as String),
                  scheduledStartAt: r['scheduled_start_at'] == null
                      ? null
                      : DateTime.parse(r['scheduled_start_at'] as String).toLocal(),
                ))
            .toList();
      }

      final reservedByRound = <String, int>{};
      if (serviceType == 'pankti') {
        final bookingRows = await supabase
            .from('bookings')
            .select('id, round_id')
            .eq('event_id', widget.eventId)
            .inFilter('status', ['requested', 'confirmed']);
        final roundIdByBooking = {
          for (final b in List<Map<String, dynamic>>.from(bookingRows))
            b['id'] as String: b['round_id'] as String?,
        };
        if (roundIdByBooking.isNotEmpty) {
          // Counted in seats, not bookings: "Round 2 · 6 seats" is what tells
          // a host whether the hall is full, where "3 bookings" does not.
          final links = await supabase
              .from('booking_seats')
              .select('booking_id')
              .inFilter('booking_id', roundIdByBooking.keys.toList());
          for (final link in List<Map<String, dynamic>>.from(links)) {
            final roundId = roundIdByBooking[link['booking_id'] as String];
            if (roundId != null) {
              reservedByRound[roundId] = (reservedByRound[roundId] ?? 0) + 1;
            }
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _serviceType = serviceType;
        _reminderLeadMinutes = reminderLead;
        _reminderChannel = reminderChannel;
        _reminderContentSid = reminderContentSid;
        _reservedByRound = reservedByRound;
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
      _showError(friendlyError(e, fallback: failureMessage));
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  /// One RPC now, rather than complete-then-insert-then-sweep from here.
  /// Bookings carry their round from the moment they are made (0014), so
  /// there is nothing to sweep; starting a round instead releases the
  /// previous sitting's seats and holds the ones this round's guests
  /// reserved, which has to happen atomically.
  Future<void> _startNextRound() => _mutate('Could not start round', () async {
        await supabase.rpc('start_round', params: {'p_event_id': widget.eventId});
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

  /// Reads the occupant behind a seat. Returns null when the booking has
  /// since gone, which is normal rather than an error — the board polls, so
  /// a seat can be freed elsewhere between a refresh and the host's tap.
  Future<_Occupant?> _loadOccupant(String bookingId) async {
    final row = await supabase
        .from('bookings')
        .select('id, party_size, status, guests(id, name, phone_number, is_vip)')
        .eq('id', bookingId)
        .maybeSingle();
    if (row == null) return null;
    final guest = row['guests'] as Map<String, dynamic>?;
    if (guest == null) return null;
    return _Occupant(
      bookingId: row['id'] as String,
      guestId: guest['id'] as String,
      name: guest['name'] as String?,
      phone: guest['phone_number'] as String?,
      partySize: row['party_size'] as int,
      bookingStatus: row['status'] as String,
      isVip: (guest['is_vip'] as bool?) ?? false,
    );
  }

  Future<void> _setVip(_Occupant occupant, bool isVip) =>
      _mutate('Could not update guest', () async {
        await supabase.from('guests').update({'is_vip': isVip}).eq('id', occupant.guestId);
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
                        // These four now account for every seat, so Total
                        // always equals their sum.
                        _metric('Total', _allSeats.length, null),
                        _metric('Occupied', _countOf('occupied'), _statusColor('occupied')),
                        _metric('Booked', _countOf('booked'), _statusColor('booked')),
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
    final highest =
        rounds.isEmpty ? 0 : rounds.map((r) => r.roundNumber).reduce((a, b) => a > b ? a : b);
    final upcoming = rounds.where((r) => r.status == 'upcoming').toList()
      ..sort((a, b) => a.roundNumber.compareTo(b.roundNumber));
    final current = rounds.where((r) => r.status == 'current').toList();

    // start_round() promotes the earliest *upcoming* round when there is one,
    // and only invents a new number when there isn't. The label has to say
    // the same thing, or a host who planned round 2 is told they're about to
    // start round 3.
    final startsNumber = upcoming.isNotEmpty ? upcoming.first.roundNumber : highest + 1;

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
                IconButton(
                  icon: const Icon(Icons.notifications_outlined),
                  tooltip: 'Reminder settings',
                  onPressed: _mutating ? null : _showReminderSettings,
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Wrap rather than Row: two buttons plus a title overflowed on a
            // narrow window.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _mutating ? null : _startNextRound,
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Start round $startsNumber'),
                ),
                // Without this there is no way to get an *upcoming* round at
                // all: starting a round makes it current immediately, so a
                // planned sitting only ever appeared when guest bookings
                // overflowed into one — and a round with no plan can never
                // send a reminder.
                OutlinedButton.icon(
                  onPressed: _mutating ? null : _addUpcomingRound,
                  icon: const Icon(Icons.more_time),
                  label: const Text('Plan a round'),
                ),
              ],
            ),
            if (rounds.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final round in rounds.reversed) _roundChip(round),
                ],
              ),
            ],
            const SizedBox(height: 8),
            // The counters above measure physical seats, and a reservation for
            // a sitting that hasn't started holds none — so a host who has
            // assigned twenty seats still reads Booked 0. Saying why, with the
            // number, stops that looking like a failed save.
            if (_reservedAhead > 0) ...[
              Text(
                '$_reservedAhead seat${_reservedAhead == 1 ? '' : 's'} reserved for rounds '
                'that have not started. The counters above show the hall right now, so '
                'those seats still read as available until you start their round.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
            ],
            Text(
              rounds.any((r) => r.status == 'upcoming' && r.scheduledStartAt != null)
                  ? 'Guests with a phone number get a $_channelLabel '
                      '$_reminderLeadMinutes minutes before a scheduled round, with a link '
                      'to cancel if they cannot make it.'
                  : 'Plan a round to give it a start time — guests are only reminded '
                      'about rounds that have one. Tap any upcoming round to change it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            // Without a template the provider refuses the send outright, and
            // the only trace is an error on a queue row the host never sees.
            // Say so here, where the setting is.
            if (_reminderContentSid == null) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'No message template set. WhatsApp, and SMS to Indian numbers, '
                      'will refuse to send until one is added in Reminder settings.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String get _channelLabel => _reminderChannel == 'whatsapp' ? 'WhatsApp message' : 'text message';

  /// How reminders go out for this event. Every field here previously
  /// required a database session to change, which put the feature out of
  /// reach of the people it is for.
  Future<void> _showReminderSettings() async {
    var channel = _reminderChannel;
    final leadController = TextEditingController(text: '$_reminderLeadMinutes');
    final sidController = TextEditingController(text: _reminderContentSid ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Reminder settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: channel,
                  decoration: const InputDecoration(labelText: 'Send by'),
                  items: const [
                    DropdownMenuItem(value: 'sms', child: Text('SMS')),
                    DropdownMenuItem(value: 'whatsapp', child: Text('WhatsApp')),
                  ],
                  onChanged: (v) => setDialogState(() => channel = v!),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: leadController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Send this many minutes before the round',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: sidController,
                  decoration: const InputDecoration(
                    labelText: 'Message template ID (optional)',
                    hintText: 'HX…',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Leave the template blank to send plain text. Carriers refuse '
                  'plain text for WhatsApp, and for SMS to Indian numbers — both '
                  'need a template registered with the provider first.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    final lead = int.tryParse(leadController.text.trim());
    final sid = sidController.text.trim();
    leadController.dispose();
    sidController.dispose();
    if (saved != true) return;

    if (lead == null || lead < 1) {
      _showError('Enter how many minutes before the round to send, as a whole number.');
      return;
    }

    await _mutate('Could not save reminder settings', () async {
      await supabase.from('events').update({
        'reminder_channel': channel,
        'reminder_lead_minutes': lead,
        // Empty means "no template", which is a real choice rather than a
        // blank string the sender would try to use as an id.
        'reminder_content_sid': sid.isEmpty ? null : sid,
      }).eq('id', widget.eventId);
    });
  }

  /// Creates the next sitting *without* starting it, then asks for its start
  /// time — the only route to a schedulable round that doesn't depend on
  /// guests happening to fill the current one.
  Future<void> _addUpcomingRound() async {
    final existing = _rounds ?? const <_Round>[];
    final nextNumber = existing.isEmpty
        ? 1
        : existing.map((r) => r.roundNumber).reduce((a, b) => a > b ? a : b) + 1;

    await _mutate('Could not plan a round', () async {
      await supabase.from('rounds').insert({
        'event_id': widget.eventId,
        'round_number': nextNumber,
        'status': 'upcoming',
      });
    });

    if (!mounted) return;
    // _mutate reloaded, so the new round is in _rounds now. Go straight into
    // the time picker: a planned round with no time does nothing useful.
    final created = (_rounds ?? const <_Round>[]).where((r) => r.roundNumber == nextNumber);
    if (created.isNotEmpty) await _scheduleRound(created.first);
  }

  /// Seats held for sittings that have not begun — the ones no status metric
  /// can account for.
  int get _reservedAhead {
    var total = 0;
    for (final round in _rounds ?? const <_Round>[]) {
      if (round.status == 'upcoming') total += _reservedByRound[round.id] ?? 0;
    }
    return total;
  }

  /// Upcoming rounds are tappable so the host can plan a start time; started
  /// and finished ones are not, because a reminder for them is either
  /// already sent or already moot.
  Widget _roundChip(_Round round) {
    final schedulable = round.status == 'upcoming';
    final label = StringBuffer('Round ${round.roundNumber}');
    if (round.scheduledStartAt != null) {
      label.write(' · ${_clock(round.scheduledStartAt!)}');
    }
    final reserved = _reservedByRound[round.id] ?? 0;
    if (reserved > 0) label.write(' · $reserved seat${reserved == 1 ? '' : 's'}');

    final chip = Chip(
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
      label: Text(label.toString()),
    );

    if (!schedulable) return chip;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: _mutating ? null : () => _scheduleRound(round),
      child: chip,
    );
  }

  String _clock(DateTime local) {
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _scheduleRound(_Round round) async {
    final now = DateTime.now();
    final existing = round.scheduledStartAt;

    final date = await showDatePicker(
      context: context,
      initialDate: existing ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Round ${round.roundNumber} — start date',
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(existing ?? now.add(const Duration(minutes: 30))),
      helpText: 'Round ${round.roundNumber} — start time',
    );
    if (time == null || !mounted) return;

    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);

    // A time already in the past can never produce a reminder — the window
    // is strictly before the round — so say so rather than silently saving
    // something that will never fire. The message names the current time
    // because otherwise the host has no way to tell what to aim for, and the
    // rejection arrives only after they have been through two pickers.
    final now2 = DateTime.now();
    if (!scheduled.isAfter(now2)) {
      _showError('That time has already passed — it is ${_clock(now2)} now. '
          'Pick a later time.');
      return;
    }

    await _mutate('Could not schedule round', () async {
      await supabase
          .from('rounds')
          .update({'scheduled_start_at': scheduled.toUtc().toIso8601String()})
          .eq('id', round.id);
    });
  }

  Widget _filterPills() {
    const options = {
      'all': 'All',
      'available': 'Available',
      'cleaning': 'Needs cleaning',
      'occupied': 'Occupied',
      'booked': 'Booked',
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
      case 'booked':
        return const Color(0xFF64B5F6); // soft blue — reserved, not arrived
      case 'occupied':
        return const Color(0xFFE57373); // soft red
      case 'cleaning':
        return const Color(0xFFFFB74D); // soft amber
      default:
        return scheme.outlineVariant;
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
                      // Reset the whole table, including seats still held
                      // for this round's guests.
                      case 'all_available':
                        _setTableStatus(tableNumber, 'available',
                            fromStatuses: {'available', 'booked', 'occupied', 'cleaning'});
                      // The party just left: flag their seats for cleaning
                      // without touching seats nobody was sitting in.
                      case 'all_cleaning':
                        _setTableStatus(tableNumber, 'cleaning', fromStatuses: {'occupied'});
                      // Cleaning finished / guests gone: put the seats that
                      // were in use back into service.
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
        onHorizontalDragEnd: _mutating
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
    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Table ${seat.tableNumber} · Seat ${seat.seatNumber}',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text('Currently ${seat.status}',
                  style: Theme.of(sheetContext).textTheme.bodySmall),
              if (seat.currentBookingId != null) ...[
                const SizedBox(height: 16),
                _OccupantPanel(
                  load: () => _loadOccupant(seat.currentBookingId!),
                  onToggleVip: (occupant, value) async {
                    await _setVip(occupant, value);
                  },
                  onVacate: () => Navigator.pop(sheetContext, 'vacate'),
                ),
              ],
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
                onSelectionChanged: (v) => Navigator.pop(sheetContext, v.first),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    // Vacating and "mark available" both free the seat, and both go through
    // _statusPatch, which releases current_booking_id as well as the status.
    if (result == 'vacate') {
      await _setSeatStatus(seat, 'available');
    } else if (result != seat.status) {
      await _setSeatStatus(seat, result);
    }
  }
}

/// Loads and shows whoever holds the seat. Kept stateful and separate so a
/// VIP toggle can re-render on its own without rebuilding the whole board
/// underneath the sheet.
class _OccupantPanel extends StatefulWidget {
  const _OccupantPanel({
    required this.load,
    required this.onToggleVip,
    required this.onVacate,
  });

  final Future<_Occupant?> Function() load;
  final Future<void> Function(_Occupant occupant, bool value) onToggleVip;
  final VoidCallback onVacate;

  @override
  State<_OccupantPanel> createState() => _OccupantPanelState();
}

class _OccupantPanelState extends State<_OccupantPanel> {
  late Future<_Occupant?> _future = widget.load();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<_Occupant?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (snapshot.hasError) {
          return Text(
            'Could not load guest: ${snapshot.error}',
            style: TextStyle(color: theme.colorScheme.error),
          );
        }
        final occupant = snapshot.data;
        if (occupant == null) {
          return Text(
            'This seat is no longer held by a booking.',
            style: theme.textTheme.bodySmall,
          );
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      occupant.name?.trim().isNotEmpty == true
                          ? occupant.name!
                          : 'Guest (no name on file)',
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (occupant.isVip) ...[
                    const SizedBox(width: 8),
                    const Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text('VIP'),
                      avatar: Icon(Icons.star, size: 14),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  'Party of ${occupant.partySize}',
                  occupant.bookingStatus,
                  // Walk-ins are assigned without a phone number, so this is
                  // routinely absent rather than missing data.
                  ?occupant.phone,
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    icon: Icon(
                      occupant.isVip ? Icons.star : Icons.star_border,
                      size: 18,
                    ),
                    label: Text(occupant.isVip ? 'Remove VIP' : 'Mark VIP'),
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() => _busy = true);
                            await widget.onToggleVip(occupant, !occupant.isVip);
                            if (mounted) {
                              setState(() {
                                _busy = false;
                                _future = widget.load();
                              });
                            }
                          },
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Vacate seat'),
                    onPressed: _busy ? null : widget.onVacate,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
