import 'package:flutter/material.dart';

import '../../core/config/legal_urls.dart';
import '../../core/privacy/gated_url_launcher.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/l10n_ext.dart';

/// The Privacy Policy and Terms links (decision 3.5): they open with Cloud OFF
/// and before consent, through [launchLegalDocument] only, and enable nothing.
class LegalLinks extends StatelessWidget {
  const LegalLinks({super.key, this.color});

  final Color? color;

  Future<void> _open(BuildContext context, Uri url) async {
    final opened = await launchLegalDocument(url);
    if (!opened && context.mounted) {
      AppToast.showError(context, context.l10n.privLinkFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final style = TextButton.styleFrom(
      foregroundColor: color,
      minimumSize: const Size(44, 44),
      textStyle: const TextStyle(decoration: TextDecoration.underline),
    );
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      children: [
        Semantics(
          link: true,
          child: TextButton(
            key: const ValueKey('legal-privacy'),
            style: style,
            onPressed: () => _open(context, kPrivacyPolicyUrl),
            child: Text(l.privPolicy),
          ),
        ),
        Semantics(
          link: true,
          child: TextButton(
            key: const ValueKey('legal-terms'),
            style: style,
            onPressed: () => _open(context, kTermsUrl),
            child: Text(l.privTerms),
          ),
        ),
      ],
    );
  }
}
