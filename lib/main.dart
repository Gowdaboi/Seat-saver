import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/router.dart';
import 'core/supabase_client.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load();
  await initSupabase();

  // Fires when the recovery-link redirect lands back on the app (see
  // HostForgotPasswordScreen) — route to the reset screen regardless of
  // which page happens to be open when Supabase's SDK picks up the token.
  supabase.auth.onAuthStateChange.listen((state) {
    if (state.event == AuthChangeEvent.passwordRecovery) {
      appRouter.go('/host/reset-password');
    }
  });

  runApp(const CateringApp());
}

class CateringApp extends StatelessWidget {
  const CateringApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Catering Seating & Rounds',
      theme: appTheme,
      routerConfig: appRouter,
    );
  }
}
