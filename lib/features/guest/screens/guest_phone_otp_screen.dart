import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_client.dart';

/// Real phone-OTP wiring via Supabase Auth (see project-spec.md "Resolved
/// decisions": guest auth is phone OTP, not anonymous/unverified). Requires
/// an SMS provider configured on the Supabase project to actually send
/// codes — will error until Twilio (or similar) is set up there.
class GuestPhoneOtpScreen extends StatefulWidget {
  const GuestPhoneOtpScreen({super.key, required this.eventId});
  final String eventId;

  @override
  State<GuestPhoneOtpScreen> createState() => _GuestPhoneOtpScreenState();
}

enum _Step { enterPhone, enterCode }

class _GuestPhoneOtpScreenState extends State<GuestPhoneOtpScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  _Step _step = _Step.enterPhone;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = 'Enter a phone number');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await supabase.auth.signInWithOtp(phone: phone);
      setState(() => _step = _Step.enterCode);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not reach Supabase: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _verifyCode() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final phone = _phoneController.text.trim();
      final res = await supabase.auth.verifyOTP(
        phone: phone,
        token: _codeController.text.trim(),
        type: OtpType.sms,
      );
      final userId = res.user?.id;
      if (userId == null) throw StateError('Verification did not return a user');

      // one guest row per verified phone identity (guests_insert_own RLS)
      await supabase.from('guests').upsert({
        'auth_user_id': userId,
        'phone_number': phone,
        if (_nameController.text.trim().isNotEmpty) 'name': _nameController.text.trim(),
      }, onConflict: 'auth_user_id');

      if (mounted) context.go('/e/${widget.eventId}/floor');
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not verify: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify your phone')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_step == _Step.enterPhone) ...[
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone number',
                      hintText: '+91XXXXXXXXXX',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Name (optional)'),
                  ),
                  const SizedBox(height: 20),
                  if (_error != null) ...[
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed: _submitting ? null : _sendCode,
                    child: _submitting
                        ? const SizedBox(
                            height: 18, width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Send code'),
                  ),
                ] else ...[
                  Text('Enter the code sent to ${_phoneController.text}'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '6-digit code'),
                  ),
                  const SizedBox(height: 20),
                  if (_error != null) ...[
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed: _submitting ? null : _verifyCode,
                    child: _submitting
                        ? const SizedBox(
                            height: 18, width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Verify'),
                  ),
                  TextButton(
                    onPressed: _submitting ? null : () => setState(() => _step = _Step.enterPhone),
                    child: const Text('Change number'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
