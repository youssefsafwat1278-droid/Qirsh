import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'data_portability_models.dart';
import 'portable_csv.dart';

const int qirshPackageVersion = 1;

const List<String> qirshPackageTables = [
  'accounts',
  'custom_categories',
  'transactions',
  'budgets',
  'subscriptions',
  'bill_payments',
  'goals',
  'goal_contributions',
  'plans',
  'plan_transaction_links',
];

class QirshPackageData {
  const QirshPackageData({
    required this.packageId,
    required this.exportedAt,
    required this.tables,
  });

  final String packageId;
  final DateTime exportedAt;
  final Map<String, PortableCsvDocument> tables;

  int get totalRows =>
      tables.values.fold(0, (total, table) => total + table.rows.length);
}

Uint8List encodeQirshPackage({
  required String packageId,
  required DateTime exportedAt,
  required Map<String, Uint8List> csvFiles,
  // MALI-030 — the exporter already knows each table's row count from writing it;
  // passing it here avoids RE-DECODING every CSV back into row maps just to count.
  Map<String, int>? rowCounts,
}) {
  final checksums = <String, String>{};
  final counts = <String, int>{};
  for (final table in qirshPackageTables) {
    final fileName = '$table.csv';
    final bytes = csvFiles[fileName];
    if (bytes == null) {
      throw DataPortabilityException('ملف $fileName مفقود من التصدير.', code: DataPortabilityError.exportFileMissing, args: [fileName]);
    }
    checksums[fileName] = sha256.convert(bytes).toString();
    counts[table] = rowCounts != null && rowCounts.containsKey(table)
        ? rowCounts[table]!
        : decodePortableCsv(bytes).rows.length;
  }
  final manifest = utf8.encode(jsonEncode({
    'format': 'qirsh-financial-data',
    'version': qirshPackageVersion,
    'package_id': packageId,
    'exported_at': exportedAt.toUtc().toIso8601String(),
    'row_counts': counts,
    'checksums': checksums,
    'privacy': {
      'raw_sms_excluded': true,
      'credentials_excluded': true,
      'sync_metadata_excluded': true,
    },
  }));

  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', manifest.length, manifest));
  for (final entry in csvFiles.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

QirshPackageData decodeQirshPackage(Uint8List bytes) {
  if (bytes.length > maxImportBytes) {
    throw const DataPortabilityException('حجم ملف ZIP أكبر من 25MB.', code: DataPortabilityError.zipTooLarge);
  }
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } catch (_) {
    throw const DataPortabilityException('ملف ZIP غير صالح أو تالف.', code: DataPortabilityError.zipInvalid);
  }

  final allowed = {
    'manifest.json',
    for (final table in qirshPackageTables) '$table.csv',
  };
  final files = <String, Uint8List>{};
  var expandedBytes = 0;
  for (final entry in archive.files) {
    final name = entry.name.replaceAll('\\', '/');
    if (!entry.isFile ||
        entry.isSymbolicLink ||
        name.startsWith('/') ||
        name.contains('../') ||
        name.contains('/./') ||
        !allowed.contains(name)) {
      throw const DataPortabilityException(
          'حزمة قرش تحتوي مسارًا أو ملفًا غير مسموح.', code: DataPortabilityError.packageUnsafePath);
    }
    if (entry.size < 0 ||
        entry.size > maxExpandedImportBytes ||
        expandedBytes + entry.size > maxExpandedImportBytes) {
      throw const DataPortabilityException(
          'حجم الحزمة بعد الفك أكبر من 100MB.', code: DataPortabilityError.packageInflatedTooLarge);
    }
    expandedBytes += entry.size;
    final content = entry.readBytes();
    if (content == null) {
      throw DataPortabilityException('تعذر قراءة $name.', code: DataPortabilityError.entryUnreadable, args: [name]);
    }
    if (content.length != entry.size) {
      throw DataPortabilityException('حجم $name لا يطابق ترويسة ZIP.', code: DataPortabilityError.entrySizeMismatch, args: [name]);
    }
    files[name] = content;
  }

  final manifestBytes = files['manifest.json'];
  if (manifestBytes == null) {
    throw const DataPortabilityException('manifest.json مفقود.', code: DataPortabilityError.manifestMissing);
  }
  final Map<String, dynamic> manifest;
  try {
    manifest = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(manifestBytes)) as Map,
    );
  } catch (_) {
    throw const DataPortabilityException('manifest.json غير صالح.', code: DataPortabilityError.manifestInvalid);
  }
  if (manifest['format'] != 'qirsh-financial-data') {
    throw const DataPortabilityException('هذا ليس ملف تصدير قرش.', code: DataPortabilityError.notAQirshExport);
  }
  final version = manifest['version'];
  if (version is! int || version > qirshPackageVersion) {
    throw const DataPortabilityException(
      'الملف من إصدار أحدث. حدّث قرش ثم أعد المحاولة.', code: DataPortabilityError.newerVersion,
    );
  }
  if (version < 1) {
    throw const DataPortabilityException('إصدار ملف قرش غير مدعوم.', code: DataPortabilityError.unsupportedVersion);
  }
  final packageId = manifest['package_id']?.toString().trim() ?? '';
  final exportedAt = DateTime.tryParse(
    manifest['exported_at']?.toString() ?? '',
  );
  if (packageId.isEmpty || exportedAt == null) {
    throw const DataPortabilityException('بيانات تعريف الحزمة ناقصة.', code: DataPortabilityError.packageMetaIncomplete);
  }
  final checksums = Map<String, dynamic>.from(
    (manifest['checksums'] as Map?) ?? const {},
  );
  final tables = <String, PortableCsvDocument>{};
  var totalRows = 0;
  for (final table in qirshPackageTables) {
    final fileName = '$table.csv';
    final content = files[fileName];
    if (content == null) {
      throw DataPortabilityException('$fileName مفقود من الحزمة.', code: DataPortabilityError.packageEntryMissing, args: [fileName]);
    }
    final expected = checksums[fileName]?.toString();
    final actual = sha256.convert(content).toString();
    if (expected == null || expected != actual) {
      throw DataPortabilityException('فشل التحقق من سلامة $fileName.', code: DataPortabilityError.integrityCheckFailed, args: [fileName]);
    }
    final document = unescapePackageCsv(decodePortableCsv(content));
    totalRows += document.rows.length;
    if (totalRows > maxImportRows) {
      throw const DataPortabilityException('الحزمة تتجاوز 100,000 صف إجمالي.', code: DataPortabilityError.packageTooManyRows);
    }
    tables[table] = document;
  }
  return QirshPackageData(
    packageId: packageId,
    exportedAt: exportedAt.toUtc(),
    tables: tables,
  );
}
