import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/supabase_client.dart';

/// List of past events (date < today) for the logged-in caterer. Nothing
/// in the schema ever gets deleted when an event "ends" — a new event is
/// created fresh each time (see project-spec.md), and what's worth
/// resurfacing afterward is a lightweight recap: how many people reserved
/// via the app, the menu, and the floor design. See
/// HostPastEventDetailScreen for that recap.
class HostPastEventsScreen extends StatefulWidget {
  const HostPastEventsScreen({super.key});

  @override
  State<HostPastEventsScreen> createState() => _HostPastEventsScreenState();
}

class _HostPastEventsScreenState extends State<HostPastEventsScreen> {
  List<Map<String, dynamic>>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) throw StateError('Not logged in');
      final caterer = await supabase
          .from('caterers')
          .select('id')
          .eq('auth_user_id', userId)
          .single();
      final today = DateTime.now();
      final todayDate =
          '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final rows = await supabase
          .from('events')
          .select('id, name, venue_name, date')
          .eq('caterer_id', caterer['id'])
          .lt('date', todayDate)
          .order('date', ascending: false);
      setState(() => _events = List<Map<String, dynamic>>.from(rows));
    } catch (e) {
      setState(() => _error = 'Could not load past events: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Past events'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : _events == null
              ? const Center(child: CircularProgressIndicator())
              : _events!.isEmpty
                  ? const Center(child: Text('No past events yet.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _events!.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final e = _events![i];
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.event_outlined),
                            title: Text(e['name'] as String),
                            subtitle: Text('${e['venue_name']} · ${e['date']}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => context.push('/host/events/past/${e['id']}'),
                          ),
                        );
                      },
                    ),
    );
  }
}
