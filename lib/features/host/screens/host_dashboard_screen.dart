import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/supabase_client.dart';

class HostDashboardScreen extends StatelessWidget {
  const HostDashboardScreen({super.key});

  static const _links = <(IconData, String, String, String)>[
    (Icons.add_circle_outline, 'Create event', 'Name, venue, date, service type, X/Y timing', '/host/events/create'),
    (Icons.qr_code, 'Event QR code', 'What guests scan to get in', '/host/events/qr'),
    (Icons.history, 'Past events', 'Reservations, menu, and floor design recap', '/host/events/past'),
    (Icons.table_restaurant, 'Design floor', 'Sections, tables, seats', '/host/floor'),
    (Icons.restaurant_menu, 'Menu', 'Add veg/non-veg menu items', '/host/menu'),
    (Icons.play_circle_outline, 'Rounds', 'Start a Pankti round / mark buffet seat cleaning', '/host/rounds'),
    (Icons.person_off_outlined, 'Review no-shows', 'Bookings past the timeout, waiting on you', '/host/noshow'),
    (Icons.qr_code_scanner, 'Scan arrival', "Scan a guest's confirmation QR", '/host/scan'),
    (Icons.support_agent, 'Call requests', 'Guest text/call requests', '/host/calls'),
    (Icons.feedback_outlined, 'Feedback form', 'Build the post-meal feedback form', '/host/feedback'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Host dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () async {
              await supabase.auth.signOut();
              if (context.mounted) context.go('/');
            },
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _links.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final (icon, title, subtitle, route) = _links[i];
          return Card(
            child: ListTile(
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(route),
            ),
          );
        },
      ),
    );
  }
}
