import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns whatever came back from Supabase into something a caterer can act on.
///
/// Raw `PostgrestException.toString()` used to reach snackbars verbatim —
/// constraint names, key tuples, uuids and all. That tells the host nothing
/// they can do anything about, and leaks internal schema shape to whoever is
/// looking at the screen.
///
/// The RPCs in this schema already raise sentences meant for people ("seat X
/// is already taken for that round"), so those pass through as-is; it is the
/// constraint violations underneath them that need translating.
String friendlyError(Object error, {required String fallback}) {
  if (error is! PostgrestException) return fallback;

  if (error.code == '23505') {
    final detail = '${error.message} ${error.details ?? ''}';
    if (detail.contains('bookings_event_id_guest_id_key')) {
      return 'This guest already has a booking for this event.';
    }
    if (detail.contains('events_caterer_name_uidx')) {
      return 'You already have an event with that name.';
    }
    if (detail.contains('tables_event_id_table_number_key')) {
      return 'That table number is already used in this event.';
    }
    return 'That already exists — nothing was saved twice.';
  }

  // 23503: a row this depends on is gone, usually because someone else
  // deleted it while this screen was open.
  if (error.code == '23503') {
    return 'Something this depends on has been removed. Refresh and try again.';
  }

  final message = error.message.trim();
  return message.isEmpty ? fallback : message;
}
