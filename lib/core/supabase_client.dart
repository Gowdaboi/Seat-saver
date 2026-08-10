import 'package:supabase_flutter/supabase_flutter.dart';

import 'env.dart';

Future<void> initSupabase() {
  return Supabase.initialize(
    url: Env.supabaseUrl,
    // supabase_flutter renamed anonKey -> publishableKey; same value, kept
    // as SUPABASE_ANON_KEY in .env since that's still the label shown in
    // most Supabase dashboards.
    publishableKey: Env.supabaseAnonKey,
  );
}

SupabaseClient get supabase => Supabase.instance.client;

/// Creates the caterers row for the current session if it doesn't already
/// exist. Deliberately not part of signUp() — with "Confirm email" enabled
/// on the Supabase project, signUp() doesn't establish a session (so there's
/// no auth.uid() for the caterers_insert_own RLS check to match against
/// until the user actually confirms their email and logs in). This runs
/// instead at every successful login, which is always a real session.
/// business_name is read from auth user metadata (set at signup time) since
/// it can't be persisted anywhere else before a session exists.
Future<void> ensureCatererProfile() async {
  final user = supabase.auth.currentUser;
  if (user == null) return;
  final existing = await supabase
      .from('caterers')
      .select('id')
      .eq('auth_user_id', user.id)
      .maybeSingle();
  if (existing != null) return;
  await supabase.from('caterers').insert({
    'auth_user_id': user.id,
    'business_name': user.userMetadata?['business_name'] as String? ?? 'My Catering Business',
    'contact_email': user.email ?? '',
  });
}
