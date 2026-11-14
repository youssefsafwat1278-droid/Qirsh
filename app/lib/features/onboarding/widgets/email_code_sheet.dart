import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/l10n_ext.dart';

enum EmailCodeResult { verified, needsCurrentCode, invalid }

/// Thrown by an `onVerify` callback for a failure that is not a wrong code;
/// the sheet shows [message] instead of the wrong-code text.
class EmailCodeFailure implements Exception {
  const EmailCodeFailure(this.message);
  final String message;
}

/// Shared by sign-in and authenticated email linking. The caller owns admission;
/// this form never installs a session or creates an application account itself.
class EmailCodeSheet extends StatefulWidget {
  const EmailCodeSheet(
      {super.key,
      required this.onSend,
      required this.onVerify,
      this.initialEmail = '',
      this.creatingAccount = false,
      this.linking = false,
      this.currentEmail});

  final Future<void> Function(String email) onSend;
  final Future<EmailCodeResult> Function(
      String email, String code, bool confirmingCurrentEmail) onVerify;
  final String initialEmail;
  final bool linking;
  final bool creatingAccount;
  final String? currentEmail;

  @override
  State<EmailCodeSheet> createState() => _EmailCodeSheetState();
}

class _EmailCodeSheetState extends State<EmailCodeSheet> {
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _form = GlobalKey<FormState>();
  Timer? _timer;
  // The server's code lifetime (GoTrue default 3600 s). After it, a rejected
  // code is reported as expired so the user requests a new one instead of
  // re-checking a dead code.
  static const _codeLifetime = Duration(minutes: 60);
  Timer? _expiryTimer;
  bool _codeExpired = false;
  int _resendSeconds = 0;
  bool _sent = false;
  bool _confirmingCurrent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    _expiryTimer?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy ||
        _resendSeconds > 0 ||
        (!_sent && !_form.currentState!.validate())) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSend(_email.text.trim());
      if (!mounted) return;
      setState(() {
        _sent = true;
        _confirmingCurrent = false;
        _code.clear();
        _resendSeconds = 60;
        _codeExpired = false;
      });
      _expiryTimer?.cancel();
      _expiryTimer = Timer(_codeLifetime, () => _codeExpired = true);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _resendSeconds--);
        if (_resendSeconds == 0) timer.cancel();
      });
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.authCodeSendFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.onVerify(
          _email.text.trim(), _code.text, _confirmingCurrent);
      if (!mounted) return;
      switch (result) {
        case EmailCodeResult.verified:
          if (ModalRoute.of(context)?.isCurrent ?? false) {
            Navigator.of(context).pop(true);
          }
        case EmailCodeResult.needsCurrentCode:
          setState(() {
            _confirmingCurrent = true;
            _code.clear();
          });
        case EmailCodeResult.invalid:
          setState(() => _error = _codeExpired
              ? context.l10n.authCodeExpired
              : context.l10n.authCodeVerifyFailed);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is EmailCodeFailure
            ? error.message
            : context.l10n.authCodeVerifyFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _codeField(
          TextEditingController controller, String label, String key) =>
      TextFormField(
        key: ValueKey(key),
        controller: controller,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        textDirection: TextDirection.ltr,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(8)
        ],
        decoration: InputDecoration(labelText: label),
        validator: (v) => RegExp(r'^\d{6,8}$').hasMatch(v ?? '')
            ? null
            : context.l10n.invalidOtpCode,
      );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return PopScope(
      canPop: !_busy,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(
                                _sent ? l.enterOtpCode : l.continueWithEmail,
                                style: Theme.of(context).textTheme.titleLarge)),
                        IconButton(
                            onPressed:
                                _busy ? null : () => Navigator.pop(context),
                            icon: const Icon(Icons.close))
                      ]),
                      const SizedBox(height: 12),
                      Text(widget.linking
                          ? l.authEmailLinkExplanation
                          : widget.creatingAccount
                              ? l.authCreateEmailExplanation
                              : l.authEmailExplanation),
                      const SizedBox(height: 16),
                      TextFormField(
                          key: const ValueKey('auth-email-input'),
                          controller: _email,
                          enabled: !_sent && !_busy,
                          keyboardType: TextInputType.emailAddress,
                          textDirection: TextDirection.ltr,
                          autocorrect: false,
                          autofillHints: const [AutofillHints.email],
                          decoration: InputDecoration(labelText: l.email),
                          validator: (v) =>
                              RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                      .hasMatch(v?.trim() ?? '')
                                  ? null
                                  : l.authInvalidEmail),
                      if (_sent) ...[
                        const SizedBox(height: 16),
                        Text(_confirmingCurrent
                            ? l.authConfirmBothEmails
                            : l.otpSentTo),
                        if (_confirmingCurrent && widget.currentEmail != null)
                          Text(widget.currentEmail!,
                              textDirection: TextDirection.ltr),
                        const SizedBox(height: 12),
                        _codeField(
                            _code,
                            _confirmingCurrent
                                ? l.authCurrentEmailCode
                                : l.enterOtpCode,
                            'auth-email-code'),
                      ],
                      if (_error != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      const SizedBox(height: 24),
                      FilledButton(
                          key: const ValueKey('auth-email-submit'),
                          onPressed: _busy || (!_sent && _resendSeconds > 0)
                              ? null
                              : (_sent ? _verify : _send),
                          child: _busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : Text(_sent
                                  ? l.verifyCode
                                  : (_resendSeconds > 0
                                      ? '${l.sendOtpCode} ($_resendSeconds)'
                                      : l.sendOtpCode))),
                      if (_sent) ...[
                        TextButton(
                            onPressed:
                                _busy || _resendSeconds > 0 ? null : _send,
                            child: Text(_resendSeconds > 0
                                ? '${l.authResendCode} ($_resendSeconds)'
                                : l.authResendCode)),
                        TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                      _sent = false;
                                      _confirmingCurrent = false;
                                      _error = null;
                                      _code.clear();
                                    }),
                            child: Text(l.authChangeEmail)),
                      ],
                    ],
                  )),
            )),
      ),
    );
  }
}
