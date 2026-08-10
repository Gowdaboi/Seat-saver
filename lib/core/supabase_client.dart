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
