import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';
import '../widgets/event_picker.dart';

/// Live call-request inbox via Supabase Realtime — the one host screen
/// where a manual refresh button isn't good enough, since the whole point
/// is the host finding out promptly that a guest needs help. call_requests
/// carries event_id directly, so it can be filtered at the stream level
/// rather than relying purely on RLS (see project-spec.md "Resolved
/// decisions" on the realtime mechanism).
class HostCallRequestsScreen extends StatefulWidget {
  const HostCallRequestsScreen({super.key});

  @override
  State<HostCallRequestsScreen> createState() => _HostCallRequestsScreenState();
}

class _HostCallRequestsScreenState extends State<HostCallRequestsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Call requests')),
      body: EventPicker(
        builder: (context, eventId) => _CallRequestsContent(key: ValueKey(eventId), eventId: eventId),
      ),
    );
  }
}

class _CallRequestsContent extends StatefulWidget {
  const _CallRequestsContent({super.key, required this.eventId});
  final String eventId;

  @override
  State<_CallRequestsContent> createState() => _CallRequestsContentState();
}

class _CallRequestsContentState extends State<_CallRequestsContent> {
  late final Stream<List<Map<String, dynamic>>> _stream;
  Map<String, int> _tableNumberById = {};

  @override
  void initState() {
    super.initState();
    _stream = supabase
        .from('call_requests')
        .stream(primaryKey: ['id'])
        .eq('event_id', widget.eventId)
        .order('created_at');
    _loadTableNumbers();
  }

  Future<void> _loadTableNumbers() async {
    try {
      final rows = await supabase
          .from('tables')
          .select('id, table_number')
          .eq('event_id', widget.eventId);
      if (!mounted) return;
      setState(() {
        _tableNumberById = {
          for (final r in List<Map<String, dynamic>>.from(rows)) r['id'] as String: r['table_number'] as int,
        };
      });
    } catch (_) {
      // table numbers are a display nicety; a failure here shouldn't block the list
    }
  }

  Future<void> _updateStatus(String id, String status) async {
    try {
      await supabase.from('call_requests').update({'status': status}).eq('id', id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load call requests: ${snapshot.error}'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snapshot.data!;
        if (rows.isEmpty) {
          return const Center(child: Text('No call requests yet.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _requestCard(rows[i]),
        );
      },
    );
  }

  Widget _requestCard(Map<String, dynamic> row) {
    final id = row['id'] as String;
    final type = row['type'] as String;
    final status = row['status'] as String;
    final message = row['message'] as String?;
    final tableId = row['table_id'] as String?;
    final tableNumber = tableId == null ? null : _tableNumberById[tableId];

    return Card(
      child: ListTile(
        leading: Icon(
          type == 'call' ? Icons.call : Icons.message_outlined,
          color: status == 'open' ? Theme.of(context).colorScheme.error : null,
        ),
        title: Text(type == 'call' ? 'Call request' : (message?.isNotEmpty == true ? message! : 'Text request')),
        subtitle: Text([
          if (tableNumber != null) 'Table $tableNumber',
          status,
        ].join(' · ')),
        trailing: status == 'resolved'
            ? Icon(Icons.check_circle, color: Colors.green.shade600)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (status == 'open')
                    TextButton(
                      onPressed: () => _updateStatus(id, 'acknowledged'),
                      child: const Text('Acknowledge'),
                    ),
                  TextButton(
                    onPressed: () => _updateStatus(id, 'resolved'),
                    child: const Text('Resolve'),
                  ),
                ],
              ),
      ),
    );
  }
}
