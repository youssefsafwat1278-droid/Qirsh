import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/auth_methods_config.dart';
import '../../core/auth/auth_coordinator.dart';
import '../../core/auth/auth_service.dart';
import '../../core/auth/email_sign_in_status.dart';
import '../../core/auth/supabase_auth_service.dart'
    show SupabaseAuthService, AuthCancelledException, googleSignInConfigured;
import '../../core/backend/supabase_config.dart';
import '../../core/security/secure_storage_options.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/widgets/glass_sheet.dart';
import '../../core/utils/l10n_ext.dart';
import '../onboarding/widgets/email_code_sheet.dart';

class SignInMethodsSheet extends ConsumerStatefulWidget {
  const SignInMethodsSheet({super.key});

  @override
  ConsumerState<SignInMethodsSheet> createState() => _SignInMethodsSheetState();
}

class _SignInMethodsSheetState extends ConsumerState<SignInMethodsSheet> {
  bool _busy = false;
  String? _message;
  bool _error = false;
  String? _emailReceipt;
  bool _loadingEmailReceipt = false;

  @override
  void initState() {
    super.initState();
    if (SupabaseConfig.isConfigured) {
      _loadingEmailReceipt = true;
      _loadEmailReceipt();
    }
  }

  Future<void> _loadEmailReceipt() async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (sessionProvesEmailCode(session)) {
        await _rememberVerifiedEmail(session!.user);
        return;
      }
      final receipt = await SecureStorageOptions.storage.read(
        key: emailSignInReceiptStorageKey,
      );
      if (mounted && _emailReceipt == null) {
        setState(() => _emailReceipt = receipt);
      }
    } catch (_) {
      // A temporarily unavailable receipt does not affect authentication.
    } finally {
      if (mounted) setState(() => _loadingEmailReceipt = false);
    }
  }

  Future<void> _rememberVerifiedEmail(User? user) async {
    final receipt = confirmedEmailFingerprint(user);
    if (receipt == null) return;
    if (mounted) setState(() => _emailReceipt = receipt);
    try {
      await SecureStorageOptions.storage.write(
        key: emailSignInReceiptStorageKey,
        value: receipt,
      );
    } catch (_) {
      // Verification succeeded even when Keychain cannot persist the label.
    }
  }

  Future<void> _link({required bool google}) async {
    if (_busy) return;
    final service = ref.read(authServiceProvider);
    if (service is! SupabaseAuthService || !SupabaseConfig.isConfigured) return;
    final client = Supabase.instance.client;
    final owner = client.auth.currentUser?.id;
    final email = client.auth.currentUser?.email;
    final admission = AppSession.instance.captureDatabaseHostAdmission();
    if (owner == null || admission?.uid != owner) return;
    final coordinator = AuthCoordinator.active;
    final intent = coordinator?.intentSeq;
    // The coordinator also binds this operation to its intent position. A
    // logout, removal or another sign-in supersedes the pending provider UI.
    bool current() =>
        AppSession.instance.status == SessionStatus.authenticated &&
        client.auth.currentUser?.id == owner &&
        !AppSession.instance.isGuest &&
        identical(AuthCoordinator.active, coordinator) &&
        coordinator?.intentSeq == intent;
    Future<void> reconcile() =>
        AppSession.instance.reconcileAccountOnboarding(client);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (google) {
        await service.linkGoogleIdentity(owner: owner, current: current);
        await reconcile();
      } else {
        final linked = await showGlassSheet<bool>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => EmailCodeSheet(
                  linking: true,
                  currentEmail: email,
                  initialEmail: email ?? '',
                  onSend: (address) async {
                    await service.sendEmailLink(
                        owner: owner, email: address, current: current);
                    await reconcile();
                  },
                  onVerify: (address, code, confirmingCurrent) async {
                    final complete = await service.verifyEmailLink(
                        owner: owner,
                        email: address,
                        code: code,
                        confirmingCurrentEmail: confirmingCurrent,
                        currentEmail: email ?? '',
                        current: current);
                    if (!complete) return EmailCodeResult.needsCurrentCode;
                    if (current()) {
                      await _rememberVerifiedEmail(client.auth.currentUser);
                    }
                    await reconcile();
                    return EmailCodeResult.verified;
                  },
                ));
        if (linked != true) return;
      }
      if (mounted) {
        setState(() {
          _error = false;
          _message = context.l10n.authLinkSuccess;
        });
      }
    } on AuthCancelledException {
      // Closing a native account picker is not a failed link.
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _message = context.l10n.authLinkFailed;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final methods = ref.watch(authMethodsConfigProvider);
    final user = SupabaseConfig.isConfigured
        ? Supabase.instance.client.auth.currentUser
        : null;
    final providers =
        user?.identities?.map((i) => i.provider).toSet() ?? <String>{};
    final emailConnected = isEmailSignInConnected(user, _emailReceipt);
    return PopScope(
        canPop: !_busy,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Expanded(
                      child: Text(l.authSignInMethods,
                          style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close))
                ]),
                const SizedBox(height: 8),
                Text(l.authSignInMethodsDescription),
                const SizedBox(height: 20),
                if (providers.contains('apple'))
                  ListTile(
                      leading: const Icon(Icons.apple),
                      title: const Text('Apple'),
                      trailing: Text(l.authLinked)),
                if (methods.google && googleSignInConfigured())
                  ListTile(
                      key: const ValueKey('link-google'),
                      leading: const Icon(Icons.account_circle_outlined),
                      title: Text(l.authLinkGoogle),
                      trailing: providers.contains('google')
                          ? Text(l.authLinked)
                          : const Icon(Icons.add),
                      onTap: _busy || providers.contains('google')
                          ? null
                          : () => _link(google: true)),
                if (methods.email)
                  ListTile(
                      key: const ValueKey('link-email'),
                      leading: const Icon(Icons.mail_outline),
                      title: Text(emailConnected ? l.email : l.authLinkEmail),
                      subtitle: user?.email == null ? null : Text(user!.email!),
                      trailing: _loadingEmailReceipt
                          ? null
                          : emailConnected
                              ? Text(l.authLinked)
                              : const Icon(Icons.add),
                      onTap: _busy || _loadingEmailReceipt || emailConnected
                          ? null
                          : () => _link(google: false)),
                if (_busy)
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator())),
                if (_message != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(_message!,
                          style: TextStyle(
                              color: _error
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context).colorScheme.primary))),
              ],
            ),
          ),
        ));
  }
}
