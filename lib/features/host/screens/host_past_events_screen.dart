import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors.dart';
import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

/// Past and archived events for the logged-in caterer.
///
/// Nothing in the schema is ever deleted when an event ends — a new event is
/// created fresh each time (see project-spec.md), and what's worth resurfacing
/// afterward is a lightweight recap: how many people reserved via the app, the
/// menu, and the floor design. See HostPastEventDetailScreen for that.
///
/// Two tabs rather than one list:
///
/// - **Past** — finished, still offered in every event picker.
/// - **Inactive** — archived, hidden from the pickers (0023).
///
/// The Inactive tab deliberately ignores the date filter that Past applies.
/// Archiving is allowed on any event, and if this view only showed archived
/// *past* events then archiving an upcoming one would strand it: gone from
/// every picker, and absent from the only screen that could bring it back.
class HostPastEventsScreen extends StatefulWidget {
  const HostPastEventsScreen({super.key});

  @override
  State<HostPastEventsScreen> createState() => _HostPastEventsScreenState();
}

class _HostPastEventsScreenState extends State<HostPastEventsScreen> {
  List<Map<String, dynamic>>? _all;
  String? _error;
  bool _mutating = false;

  /// Events with a round in progress. Archiving one would remove it from the
  /// dropdown the host reaches the Rounds screen through, mid-service.
  Set<String> _liveEventIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _todayIso() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) throw StateError('Not logged in');
      final caterer =
          await supabase.from('caterers').select('id').eq('auth_user_id', userId).single();

      // One query for both tabs: partitioning in Dart keeps the counts on the
      // tab labels honest without a second round trip.
      final rows = await supabase
          .from('events')
          .select('id, name, venue_name, date, archived_at')
          .eq('caterer_id', caterer['id'])
          .order('date', ascending: false);
      final all = List<Map<String, dynamic>>.from(rows);

      final live = await supabase
          .from('rounds')
          .select('event_id')
          .eq('status', 'current')
          .inFilter('event_id', all.map((e) => e['id'] as String).toList());

      if (!mounted) return;
      setState(() {
        _all = all;
        _liveEventIds = {
          for (final r in List<Map<String, dynamic>>.from(live)) r['event_id'] as String,
        };
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load events: $e');
    }
  }

  List<Map<String, dynamic>> get _past {
    final today = _todayIso();
    return (_all ?? [])
        .where((e) => e['archived_at'] == null && (e['date'] as String).compareTo(today) < 0)
        .toList();
  }

  List<Map<String, dynamic>> get _inactive =>
      (_all ?? []).where((e) => e['archived_at'] != null).toList();

  Future<void> _setArchived(Map<String, dynamic> event, bool archived) async {
    setState(() => _mutating = true);
    final messenger = ScaffoldMessenger.of(context);
    final name = event['name'] as String;
    try {
      await supabase
          .from('events')
          .update({'archived_at': archived ? DateTime.now().toUtc().toIso8601String() : null})
          .eq('id', event['id'] as String);
      await _load();
      messenger.showSnackBar(
        SnackBar(
          content: Text(archived ? '"$name" moved to Inactive.' : '"$name" restored.'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _setArchived(event, !archived),
          ),
        ),
      );
    } catch (e) {
      // The database refuses to archive an event with a round in progress;
      // that message is written for people, so it passes through.
      messenger.showSnackBar(
        SnackBar(content: Text(friendlyError(e, fallback: 'Could not update the event.'))),
      );
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Past events'),
          actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
          bottom: TabBar(
            tabs: [
              Tab(text: _all == null ? 'Past' : 'Past (${_past.length})'),
              Tab(text: _all == null ? 'Inactive' : 'Inactive (${_inactive.length})'),
            ],
          ),
        ),
        body: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
            : _all == null
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    children: [
                      _list(
                        _past,
                        empty: 'No past events yet.',
                        archived: false,
                      ),
                      _list(
                        _inactive,
                        empty: 'Nothing archived.\n\n'
                            'Use "Mark as inactive" on a past event to hide it from the '
                            'event pickers without deleting anything.',
                        archived: true,
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _list(
    List<Map<String, dynamic>> events, {
    required String empty,
    required bool archived,
  }) {
    if (events.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(empty, textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: events.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _eventCard(events[i], archived: archived),
    );
  }

  Widget _eventCard(Map<String, dynamic> event, {required bool archived}) {
    final id = event['id'] as String;
    final isLive = _liveEventIds.contains(id);

    return Card(
      child: ListTile(
        leading: Icon(archived ? Icons.inventory_2_outlined : Icons.event_outlined),
        title: Text(eventPickerLabel(event)),
        subtitle: isLive && !archived
            ? Text(
                'A round is running',
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              )
            : null,
        // A single trailing widget: ListTile constrains that slot, and two
        // side by side clip (see CLAUDE.md).
        trailing: PopupMenuButton<String>(
          tooltip: 'Event actions',
          enabled: !_mutating,
          onSelected: (value) {
            if (value == 'open') {
              context.push('/host/events/past/$id');
            } else {
              _setArchived(event, value == 'archive');
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'open', child: Text('View recap')),
            if (archived)
              const PopupMenuItem(
                value: 'restore',
                child: Text('Restore to active'),
              )
            else
              PopupMenuItem(
                value: 'archive',
                // Disabled rather than hidden, so the reason is visible
                // instead of the action just being missing.
                enabled: !isLive,
                child: Text(
                  isLive ? 'Mark as inactive (round running)' : 'Mark as inactive',
                ),
              ),
          ],
        ),
        onTap: () => context.push('/host/events/past/$id'),
      ),
    );
  }
}
