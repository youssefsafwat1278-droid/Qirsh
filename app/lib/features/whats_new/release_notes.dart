import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Release notes bundled in the binary, so the What's new page and sheet work
/// offline and with Cloud OFF. Newest release first.
const kReleaseNotesAsset = 'assets/whats_new/release_notes.json';

class ReleaseNotes {
  const ReleaseNotes(
      {required this.version, required this.ar, required this.en});

  final String version;
  final List<String> ar;
  final List<String> en;

  List<String> forLanguage(String languageCode) =>
      languageCode == 'ar' ? ar : en;
}

Future<List<ReleaseNotes>> loadBundledReleaseNotes(
    [AssetBundle? bundle]) async {
  final raw = await (bundle ?? rootBundle).loadString(kReleaseNotesAsset);
  final releases =
      (jsonDecode(raw) as Map<String, Object?>)['releases'] as List;
  return [
    for (final r in releases.cast<Map<String, Object?>>())
      ReleaseNotes(
        version: r['version'] as String,
        ar: (r['ar'] as List).cast<String>(),
        en: (r['en'] as List).cast<String>(),
      ),
  ];
}

final bundledReleaseNotesProvider =
    FutureProvider<List<ReleaseNotes>>((ref) => loadBundledReleaseNotes());
