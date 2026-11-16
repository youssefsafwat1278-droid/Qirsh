import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import '../../features/coupons/coupon_models.dart';

String _compactSenderToken(String input) =>
    input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u0600-\u06ff]+'), '');

bool _senderMatchesAlias(String rawSender, String compactSender, String alias) {
  final compactAlias = _compactSenderToken(alias);
  if (compactAlias.isEmpty) return false;
  final parts = rawSender
      .split(RegExp(r'[^a-z0-9\u0600-\u06ff]+'))
      .map(_compactSenderToken)
      .where((part) => part.isNotEmpty);
  return compactSender == compactAlias ||
      compactSender.startsWith(compactAlias) ||
      parts.contains(compactAlias);
}

class CatalogCategories {
  CatalogCategories._();

  static const banks = 'banks';
  static const parsers = 'parsers';
  static const currencies = 'currencies';
  static const countries = 'countries';
  static const categories = 'categories';
  static const merchantKeywords = 'merchant_keywords';

  /// COUPONS Phase 1 — the canonical merchant catalog and its reviewed aliases.
  /// Two categories rather than one because they version independently: adding
  /// an alias is a frequent, small change and must not force every device to
  /// re-download the merchant list.
  static const catalogMerchants = 'catalog_merchants';
  static const merchantAliases = 'merchant_aliases';

  static const phase0 = <String>[
    banks,
    parsers,
    currencies,
    countries,
  ];

  static const syncable = <String>[
    banks,
    parsers,
    currencies,
    countries,
    categories,
    merchantKeywords,
    catalogMerchants,
    merchantAliases,
  ];
}

class CatalogMetadata {
  const CatalogMetadata({
    required this.category,
    required this.serverVersion,
    required this.localVersion,
    required this.lastSyncedAt,
    required this.etag,
  });

  final String category;
  final int serverVersion;
  final int localVersion;
  final DateTime? lastSyncedAt;
  final String? etag;
}

class CatalogMetadataDao {
  CatalogMetadataDao(this._db);

  final AppDatabase _db;

  Future<CatalogMetadata?> getVersion(String category) async {
    final row = await _db.customSelect(
      '''
        SELECT category, server_version, local_version, last_synced_at, etag
        FROM catalog_metadata
        WHERE category = ?
        LIMIT 1;
      ''',
      variables: [Variable.withString(category)],
    ).getSingleOrNull();
    if (row == null) return null;
    return _metadataFromRow(row);
  }

  Future<void> upsertVersion(
    String category,
    int serverV,
    int localV,
  ) async {
    await _db.customInsert(
      '''
        INSERT INTO catalog_metadata(category, server_version, local_version, last_synced_at, etag)
        VALUES (?, ?, ?, NULL, NULL)
        ON CONFLICT(category) DO UPDATE SET
          server_version = excluded.server_version,
          local_version = excluded.local_version;
      ''',
      variables: [
        Variable.withString(category),
        Variable.withInt(serverV),
        Variable.withInt(localV),
      ],
    );
  }

  Future<void> setLastSynced(String category, DateTime value) async {
    await _db.customInsert(
      '''
        INSERT INTO catalog_metadata(category, server_version, local_version, last_synced_at, etag)
        VALUES (?, 0, 0, ?, NULL)
        ON CONFLICT(category) DO UPDATE SET
          last_synced_at = excluded.last_synced_at;
      ''',
      variables: [
        Variable.withString(category),
        Variable.withString(dateTimeToSql(value)),
      ],
    );
  }

  CatalogMetadata _metadataFromRow(QueryRow row) {
    final synced = row.readNullable<String>('last_synced_at');
    return CatalogMetadata(
      category: row.read<String>('category'),
      serverVersion: row.read<int>('server_version'),
      localVersion: row.read<int>('local_version'),
      lastSyncedAt: synced == null ? null : dateTimeFromSql(synced),
      etag: row.readNullable<String>('etag'),
    );
  }
}

class RemoteBank {
  const RemoteBank({
    required this.id,
    required this.nameAr,
    required this.nameEn,
    required this.shortCode,
    required this.logoUrl,
    required this.countryCode,
    required this.smsSenders,
    required this.supportedCurrencies,
    required this.colorHex,
    required this.isActive,
    required this.sortOrder,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String id;
  final String nameAr;
  final String nameEn;
  final String shortCode;
  final String? logoUrl;
  final String countryCode;
  final List<String> smsSenders;
  final List<String> supportedCurrencies;
  final String? colorHex;
  final bool isActive;
  final int sortOrder;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteBank fromJson(Map<String, Object?> json) {
    return RemoteBank(
      id: json['id'].toString(),
      nameAr: json['name_ar'].toString(),
      nameEn: json['name_en'].toString(),
      shortCode: json['short_code'].toString(),
      logoUrl: _optionalString(json['logo_url']),
      countryCode: json['country_code'].toString(),
      smsSenders: _stringList(json['sms_senders']),
      supportedCurrencies: _stringList(json['supported_currencies']),
      colorHex: _optionalString(json['color_hex']),
      isActive: json['is_active'] as bool? ?? true,
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class RemoteBanksDao {
  RemoteBanksDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteBank> banks) async {
    await _db.transaction(() async {
      for (final bank in banks) {
        await _db.customInsert(
          '''
            INSERT INTO remote_banks(
              id, name_ar, name_en, short_code, logo_url, country_code,
              sms_senders, supported_currencies, color_hex, is_active,
              sort_order, is_deleted, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name_ar = excluded.name_ar,
              name_en = excluded.name_en,
              short_code = excluded.short_code,
              logo_url = excluded.logo_url,
              country_code = excluded.country_code,
              sms_senders = excluded.sms_senders,
              supported_currencies = excluded.supported_currencies,
              color_hex = excluded.color_hex,
              is_active = excluded.is_active,
              sort_order = excluded.sort_order,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(bank.id),
            Variable.withString(bank.nameAr),
            Variable.withString(bank.nameEn),
            Variable.withString(bank.shortCode),
            _nullableString(bank.logoUrl),
            Variable.withString(bank.countryCode),
            Variable.withString(jsonEncode(bank.smsSenders)),
            Variable.withString(jsonEncode(bank.supportedCurrencies)),
            _nullableString(bank.colorHex),
            Variable.withInt(boolToSql(bank.isActive)),
            Variable.withInt(bank.sortOrder),
            Variable.withInt(boolToSql(bank.isDeleted)),
            Variable.withString(dateTimeToSql(bank.updatedAt)),
          ],
        );
      }
    });
  }

  Future<void> markDeleted(List<String> ids) async {
    await _db.transaction(() async {
      for (final id in ids) {
        await _db.customUpdate(
          '''
            UPDATE remote_banks
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE id = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(id),
          ],
        );
      }
    });
  }

  Future<List<RemoteBank>> getActiveBanks(String countryCode) async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_banks
        WHERE country_code = ?
          AND is_active = 1
          AND is_deleted = 0
        ORDER BY sort_order ASC, name_ar ASC;
      ''',
      variables: [Variable.withString(countryCode)],
    ).get();
    return rows.map(_bankFromRow).toList();
  }

  Future<RemoteBank?> getBankBySender(String sender) async {
    final normalized = sender.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    final compactSender = _compactSenderToken(normalized);
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_banks
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY sort_order ASC, name_ar ASC;
      ''',
    ).get();
    for (final row in rows) {
      final bank = _bankFromRow(row);
      final matched = bank.smsSenders.any(
        (candidate) => _senderMatchesAlias(
          normalized,
          compactSender,
          candidate,
        ),
      );
      if (matched) return bank;
    }
    return null;
  }

  RemoteBank _bankFromRow(QueryRow row) {
    return RemoteBank(
      id: row.read<String>('id'),
      nameAr: row.read<String>('name_ar'),
      nameEn: row.read<String>('name_en'),
      shortCode: row.read<String>('short_code'),
      logoUrl: row.readNullable<String>('logo_url'),
      countryCode: row.read<String>('country_code'),
      smsSenders: _jsonStringList(row.read<String>('sms_senders')),
      supportedCurrencies:
          _jsonStringList(row.read<String>('supported_currencies')),
      colorHex: row.readNullable<String>('color_hex'),
      isActive: sqlToBool(row.read<int>('is_active')),
      sortOrder: row.read<int>('sort_order'),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteParser {
  const RemoteParser({
    required this.id,
    required this.bankId,
    required this.senderPattern,
    required this.messagePattern,
    required this.transactionType,
    required this.language,
    required this.priority,
    required this.extractedFields,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String id;
  final String bankId;
  final String senderPattern;
  final String messagePattern;
  final String transactionType;
  final String language;
  final int priority;
  final Map<String, Object?> extractedFields;
  final bool isActive;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteParser fromJson(Map<String, Object?> json) {
    return RemoteParser(
      id: json['id'].toString(),
      bankId: json['bank_id'].toString(),
      senderPattern: json['sender_pattern'].toString(),
      messagePattern: json['message_pattern'].toString(),
      transactionType: json['transaction_type'].toString(),
      language: json['language'].toString(),
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      extractedFields: _objectMap(json['extracted_fields']),
      isActive: json['is_active'] as bool? ?? true,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
  /// The same rule with a different active flag.
  ///
  /// Used by the seeder to insert the bundle INACTIVE in one statement: the
  /// bundle carries no validation metadata, so an active bundled rule would be
  /// money authority the server gate never granted.
  RemoteParser copyWithActive(bool active) => RemoteParser(
        id: id,
        bankId: bankId,
        senderPattern: senderPattern,
        messagePattern: messagePattern,
        transactionType: transactionType,
        language: language,
        priority: priority,
        extractedFields: extractedFields,
        isActive: active,
        isDeleted: isDeleted,
        updatedAt: updatedAt,
      );

}

class RemoteParsersDao {
  RemoteParsersDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteParser> parsers) async {
    await _db.transaction(() async {
      for (final parser in parsers) {
        await _db.customInsert(
          '''
            INSERT INTO remote_parsers(
              id, bank_id, sender_pattern, message_pattern, transaction_type,
              language, priority, extracted_fields, is_active, is_deleted,
              updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              bank_id = excluded.bank_id,
              sender_pattern = excluded.sender_pattern,
              message_pattern = excluded.message_pattern,
              transaction_type = excluded.transaction_type,
              language = excluded.language,
              priority = excluded.priority,
              extracted_fields = excluded.extracted_fields,
              is_active = excluded.is_active,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(parser.id),
            Variable.withString(parser.bankId),
            Variable.withString(parser.senderPattern),
            Variable.withString(parser.messagePattern),
            Variable.withString(parser.transactionType),
            Variable.withString(parser.language),
            Variable.withInt(parser.priority),
            Variable.withString(jsonEncode(parser.extractedFields)),
            Variable.withInt(boolToSql(parser.isActive)),
            Variable.withInt(boolToSql(parser.isDeleted)),
            Variable.withString(dateTimeToSql(parser.updatedAt)),
          ],
        );
      }
    });
  }

  Future<void> markDeleted(List<String> ids) async {
    await _db.transaction(() async {
      for (final id in ids) {
        await _db.customUpdate(
          '''
            UPDATE remote_parsers
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE id = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(id),
          ],
        );
      }
    });
  }
  /// Converges the local parser set on the server's authoritative servable set.
  ///
  /// Deactivates every local rule absent from [servableIds] AND activates every
  /// rule present in it. Both directions matter:
  ///
  ///  * DEACTIVATE — a rule stops being servable by demotion, deactivation or
  ///    deletion. The revoked row is filtered out of `items` by the same
  ///    validation gate that revoked it, and only deletion fills `deleted_ids`,
  ///    so the delta carries no instruction to drop it.
  ///  * ACTIVATE — a rule re-validated later must come back. On a forced
  ///    authority refresh the device is already at the server's version, so
  ///    `items` is empty and no upsert would ever flip `is_active` back on.
  ///
  /// The caller must have PROVEN the snapshot complete first
  /// (`_authoritativeServableIdsImpl`); this method trusts its argument.
  Future<void> applyAuthoritativeServableSet(List<String> servableIds) async {
    await _db.transaction(() async {
      if (servableIds.isEmpty) {
        // The server says NOTHING is servable — the current production state.
        // It must be honoured rather than mistaken for an empty response, or a
        // revoked rule survives exactly when every rule has been revoked.
        await _db.customUpdate(
          'UPDATE remote_parsers SET is_active = 0 WHERE is_active = 1;',
        );
        return;
      }
      final placeholders = List.filled(servableIds.length, '?').join(',');
      final vars = servableIds.map(Variable.withString).toList();
      await _db.customUpdate(
        'UPDATE remote_parsers SET is_active = 0 '
        'WHERE is_active = 1 AND id NOT IN ($placeholders);',
        variables: vars,
      );
      // Never resurrect a tombstoned rule: is_deleted stays authoritative.
      await _db.customUpdate(
        'UPDATE remote_parsers SET is_active = 1 '
        'WHERE is_active = 0 AND is_deleted = 0 AND id IN ($placeholders);',
        variables: vars,
      );
    });
  }

  /// Deactivates every active parser. Used by the authority-epoch upgrade to
  /// drop legacy authority BEFORE any rule can be consulted, and by the seeder.
  Future<void> deactivateAll() async {
    await _db.customUpdate(
      'UPDATE remote_parsers SET is_active = 0 WHERE is_active = 1;',
    );
  }



  Future<List<RemoteParser>> getActiveParsersByBankId(String bankId) async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_parsers
        WHERE bank_id = ?
          AND is_active = 1
          AND is_deleted = 0
        ORDER BY priority DESC, updated_at DESC;
      ''',
      variables: [Variable.withString(bankId)],
    ).get();
    return rows.map(_parserFromRow).toList();
  }

  Future<List<RemoteParser>> getAllActiveParsers() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_parsers
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY priority DESC, updated_at DESC;
      ''',
    ).get();
    return rows.map(_parserFromRow).toList();
  }

  RemoteParser _parserFromRow(QueryRow row) {
    return RemoteParser(
      id: row.read<String>('id'),
      bankId: row.read<String>('bank_id'),
      senderPattern: row.read<String>('sender_pattern'),
      messagePattern: row.read<String>('message_pattern'),
      transactionType: row.read<String>('transaction_type'),
      language: row.read<String>('language'),
      priority: row.read<int>('priority'),
      extractedFields: _jsonObjectMap(row.read<String>('extracted_fields')),
      isActive: sqlToBool(row.read<int>('is_active')),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteCurrency {
  const RemoteCurrency({
    required this.code,
    required this.nameAr,
    required this.nameEn,
    required this.symbol,
    required this.decimalPlaces,
    required this.countryCodes,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String code;
  final String nameAr;
  final String nameEn;
  final String symbol;
  final int decimalPlaces;
  final List<String> countryCodes;
  final bool isActive;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteCurrency fromJson(Map<String, Object?> json) {
    return RemoteCurrency(
      code: json['code'].toString(),
      nameAr: json['name_ar'].toString(),
      nameEn: json['name_en'].toString(),
      symbol: json['symbol'].toString(),
      decimalPlaces: (json['decimal_places'] as num?)?.toInt() ?? 2,
      countryCodes: _stringList(json['country_codes']),
      isActive: json['is_active'] as bool? ?? true,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class RemoteCurrenciesDao {
  RemoteCurrenciesDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteCurrency> currencies) async {
    await _db.transaction(() async {
      for (final currency in currencies) {
        await _db.customInsert(
          '''
            INSERT INTO remote_currencies(
              code, name_ar, name_en, symbol, decimal_places, country_codes,
              is_active, is_deleted, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(code) DO UPDATE SET
              name_ar = excluded.name_ar,
              name_en = excluded.name_en,
              symbol = excluded.symbol,
              decimal_places = excluded.decimal_places,
              country_codes = excluded.country_codes,
              is_active = excluded.is_active,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(currency.code),
            Variable.withString(currency.nameAr),
            Variable.withString(currency.nameEn),
            Variable.withString(currency.symbol),
            Variable.withInt(currency.decimalPlaces),
            Variable.withString(jsonEncode(currency.countryCodes)),
            Variable.withInt(boolToSql(currency.isActive)),
            Variable.withInt(boolToSql(currency.isDeleted)),
            Variable.withString(dateTimeToSql(currency.updatedAt)),
          ],
        );
      }
    });
  }

  Future<List<RemoteCurrency>> getActiveCurrencies() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_currencies
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY code ASC;
      ''',
    ).get();
    return rows.map(_currencyFromRow).toList();
  }

  Future<void> markDeleted(List<String> codes) async {
    await _db.transaction(() async {
      for (final code in codes) {
        await _db.customUpdate(
          '''
            UPDATE remote_currencies
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE code = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(code),
          ],
        );
      }
    });
  }

  Future<List<RemoteCurrency>> getCurrenciesForCountry(
    String countryCode,
  ) async {
    final normalized = countryCode.trim().toUpperCase();
    final currencies = await getActiveCurrencies();
    return currencies
        .where((currency) => currency.countryCodes.contains(normalized))
        .toList(growable: false);
  }

  RemoteCurrency _currencyFromRow(QueryRow row) {
    return RemoteCurrency(
      code: row.read<String>('code'),
      nameAr: row.read<String>('name_ar'),
      nameEn: row.read<String>('name_en'),
      symbol: row.read<String>('symbol'),
      decimalPlaces: row.read<int>('decimal_places'),
      countryCodes: _jsonStringList(row.read<String>('country_codes')),
      isActive: sqlToBool(row.read<int>('is_active')),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteCountry {
  const RemoteCountry({
    required this.code,
    required this.nameAr,
    required this.nameEn,
    required this.flagEmoji,
    required this.phonePrefix,
    required this.isSupported,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String code;
  final String nameAr;
  final String nameEn;
  final String flagEmoji;
  final String phonePrefix;
  final bool isSupported;
  final bool isActive;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteCountry fromJson(Map<String, Object?> json) {
    return RemoteCountry(
      code: json['code'].toString(),
      nameAr: json['name_ar'].toString(),
      nameEn: json['name_en'].toString(),
      flagEmoji: json['flag_emoji'].toString(),
      phonePrefix: json['phone_prefix'].toString(),
      isSupported: json['is_supported'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class RemoteCountriesDao {
  RemoteCountriesDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteCountry> countries) async {
    await _db.transaction(() async {
      for (final country in countries) {
        await _db.customInsert(
          '''
            INSERT INTO remote_countries(
              code, name_ar, name_en, flag_emoji, phone_prefix, is_supported,
              is_active, is_deleted, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(code) DO UPDATE SET
              name_ar = excluded.name_ar,
              name_en = excluded.name_en,
              flag_emoji = excluded.flag_emoji,
              phone_prefix = excluded.phone_prefix,
              is_supported = excluded.is_supported,
              is_active = excluded.is_active,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(country.code),
            Variable.withString(country.nameAr),
            Variable.withString(country.nameEn),
            Variable.withString(country.flagEmoji),
            Variable.withString(country.phonePrefix),
            Variable.withInt(boolToSql(country.isSupported)),
            Variable.withInt(boolToSql(country.isActive)),
            Variable.withInt(boolToSql(country.isDeleted)),
            Variable.withString(dateTimeToSql(country.updatedAt)),
          ],
        );
      }
    });
  }

  Future<List<RemoteCountry>> getSupportedCountries() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_countries
        WHERE is_supported = 1
          AND is_active = 1
          AND is_deleted = 0
        ORDER BY name_ar ASC;
      ''',
    ).get();
    return rows.map(_countryFromRow).toList();
  }

  Future<void> markDeleted(List<String> codes) async {
    await _db.transaction(() async {
      for (final code in codes) {
        await _db.customUpdate(
          '''
            UPDATE remote_countries
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE code = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(code),
          ],
        );
      }
    });
  }

  Future<RemoteCountry?> getByCode(String code) async {
    final row = await _db.customSelect(
      '''
        SELECT *
        FROM remote_countries
        WHERE code = ?
          AND is_active = 1
          AND is_deleted = 0
        LIMIT 1;
      ''',
      variables: [Variable.withString(code.trim().toUpperCase())],
    ).getSingleOrNull();
    return row == null ? null : _countryFromRow(row);
  }

  RemoteCountry _countryFromRow(QueryRow row) {
    return RemoteCountry(
      code: row.read<String>('code'),
      nameAr: row.read<String>('name_ar'),
      nameEn: row.read<String>('name_en'),
      flagEmoji: row.read<String>('flag_emoji'),
      phonePrefix: row.read<String>('phone_prefix'),
      isSupported: sqlToBool(row.read<int>('is_supported')),
      isActive: sqlToBool(row.read<int>('is_active')),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteCategory {
  const RemoteCategory({
    required this.id,
    required this.key,
    required this.nameAr,
    required this.nameEn,
    required this.icon,
    required this.colorHex,
    required this.parentKey,
    required this.type,
    required this.sortOrder,
    required this.isSystem,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String id;
  final String key;
  final String nameAr;
  final String nameEn;
  final String icon;
  final String colorHex;
  final String? parentKey;
  final String type;
  final int sortOrder;
  final bool isSystem;
  final bool isActive;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteCategory fromJson(Map<String, Object?> json) {
    return RemoteCategory(
      id: json['id'].toString(),
      key: json['key'].toString(),
      nameAr: json['name_ar'].toString(),
      nameEn: json['name_en'].toString(),
      icon: json['icon'].toString(),
      colorHex: json['color_hex'].toString(),
      parentKey: _optionalString(json['parent_key']),
      type: json['type'].toString(),
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      isSystem: json['is_system'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class RemoteCategoriesDao {
  RemoteCategoriesDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteCategory> categories) async {
    await _db.transaction(() async {
      for (final category in categories) {
        await _db.customInsert(
          '''
            INSERT INTO remote_categories(
              id, key, name_ar, name_en, icon, color_hex, parent_key, type,
              sort_order, is_system, is_active, is_deleted, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              key = excluded.key,
              name_ar = excluded.name_ar,
              name_en = excluded.name_en,
              icon = excluded.icon,
              color_hex = excluded.color_hex,
              parent_key = excluded.parent_key,
              type = excluded.type,
              sort_order = excluded.sort_order,
              is_system = excluded.is_system,
              is_active = excluded.is_active,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(category.id),
            Variable.withString(category.key),
            Variable.withString(category.nameAr),
            Variable.withString(category.nameEn),
            Variable.withString(category.icon),
            Variable.withString(category.colorHex),
            _nullableString(category.parentKey),
            Variable.withString(category.type),
            Variable.withInt(category.sortOrder),
            Variable.withInt(boolToSql(category.isSystem)),
            Variable.withInt(boolToSql(category.isActive)),
            Variable.withInt(boolToSql(category.isDeleted)),
            Variable.withString(dateTimeToSql(category.updatedAt)),
          ],
        );
      }
    });
  }

  Future<void> markDeleted(List<String> ids) async {
    await _db.transaction(() async {
      for (final id in ids) {
        await _db.customUpdate(
          '''
            UPDATE remote_categories
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE id = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(id),
          ],
        );
      }
    });
  }

  Future<RemoteCategory?> getByKey(String key) async {
    final row = await _db.customSelect(
      '''
        SELECT *
        FROM remote_categories
        WHERE key = ?
          AND is_active = 1
          AND is_deleted = 0
        LIMIT 1;
      ''',
      variables: [Variable.withString(key)],
    ).getSingleOrNull();
    return row == null ? null : _categoryFromRow(row);
  }

  Future<List<RemoteCategory>> getActiveCategories() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_categories
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY sort_order ASC, name_ar ASC;
      ''',
    ).get();
    return rows.map(_categoryFromRow).toList();
  }

  Future<List<RemoteCategory>> getSystemCategories() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_categories
        WHERE is_system = 1
          AND is_active = 1
          AND is_deleted = 0
        ORDER BY sort_order ASC, name_ar ASC;
      ''',
    ).get();
    return rows.map(_categoryFromRow).toList();
  }

  RemoteCategory _categoryFromRow(QueryRow row) {
    return RemoteCategory(
      id: row.read<String>('id'),
      key: row.read<String>('key'),
      nameAr: row.read<String>('name_ar'),
      nameEn: row.read<String>('name_en'),
      icon: row.read<String>('icon'),
      colorHex: row.read<String>('color_hex'),
      parentKey: row.readNullable<String>('parent_key'),
      type: row.read<String>('type'),
      sortOrder: row.read<int>('sort_order'),
      isSystem: sqlToBool(row.read<int>('is_system')),
      isActive: sqlToBool(row.read<int>('is_active')),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteMerchantKeyword {
  const RemoteMerchantKeyword({
    required this.id,
    required this.keyword,
    required this.categoryKey,
    required this.language,
    required this.countryCode,
    required this.priority,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
    this.logoUrl,
  });

  final String id;
  final String keyword;
  final String categoryKey;
  final String language;
  final String countryCode;
  final int priority;
  final bool isActive;
  final bool isDeleted;
  final String updatedAt;

  /// Optional brand logo URL (admin-managed). When present the UI shows it
  /// instead of a category icon / drawn brand mark.
  final String? logoUrl;

  static RemoteMerchantKeyword fromJson(Map<String, Object?> json) {
    return RemoteMerchantKeyword(
      id: json['id'] as String,
      keyword: json['keyword'] as String,
      categoryKey: json['category_key'] as String,
      language: (json['language'] as String?) ?? 'any',
      countryCode: (json['country_code'] as String?) ?? 'ALL',
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      isActive: _boolFromJson(json['is_active'], defaultValue: true),
      isDeleted: _boolFromJson(json['is_deleted']),
      updatedAt: json['updated_at'] as String,
      logoUrl: json['logo_url'] as String?,
    );
  }
}

class RemoteMerchantKeywordsDao {
  const RemoteMerchantKeywordsDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteMerchantKeyword> keywords) async {
    for (final kw in keywords) {
      await _db.customInsert(
        '''
          INSERT INTO remote_merchant_keywords(
            id, keyword, category_key, language, country_code,
            priority, is_active, is_deleted, updated_at, logo_url
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            keyword = excluded.keyword,
            category_key = excluded.category_key,
            language = excluded.language,
            country_code = excluded.country_code,
            priority = excluded.priority,
            is_active = excluded.is_active,
            is_deleted = excluded.is_deleted,
            updated_at = excluded.updated_at,
            logo_url = excluded.logo_url;
        ''',
        variables: [
          Variable.withString(kw.id),
          Variable.withString(kw.keyword),
          Variable.withString(kw.categoryKey),
          Variable.withString(kw.language),
          Variable.withString(kw.countryCode),
          Variable.withInt(kw.priority),
          Variable.withInt(kw.isActive ? 1 : 0),
          Variable.withInt(kw.isDeleted ? 1 : 0),
          Variable.withString(kw.updatedAt),
          Variable<String>(kw.logoUrl),
        ],
      );
    }
  }

  Future<void> markDeleted(List<String> ids) async {
    for (final id in ids) {
      await _db.customUpdate(
        'UPDATE remote_merchant_keywords SET is_deleted = 1 WHERE id = ?;',
        variables: [Variable.withString(id)],
      );
    }
  }

  /// Returns active, non-deleted keywords for [countryCode] and 'ALL',
  /// ordered by priority descending (highest priority checked first).
  Future<List<RemoteMerchantKeyword>> getActiveForCountry(
      String countryCode) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM remote_merchant_keywords
        WHERE is_active = 1
          AND is_deleted = 0
          AND (country_code = ? OR country_code = 'ALL')
        ORDER BY priority DESC;
      ''',
      variables: [Variable.withString(countryCode.toUpperCase())],
    ).get();
    return rows
        .map((r) => RemoteMerchantKeyword(
              id: r.read<String>('id'),
              keyword: r.read<String>('keyword'),
              categoryKey: r.read<String>('category_key'),
              language: r.read<String>('language'),
              countryCode: r.read<String>('country_code'),
              priority: r.read<int>('priority'),
              isActive: r.read<int>('is_active') != 0,
              isDeleted: r.read<int>('is_deleted') != 0,
              updatedAt: r.read<String>('updated_at'),
              logoUrl: r.readNullable<String>('logo_url'),
            ))
        .toList();
  }

  /// Returns all active, non-deleted keywords ordered by priority DESC.
  /// Used as the interim default until 4C wires a real country code from
  /// UserSettings — applying all keywords avoids silently excluding EG/Gulf
  /// markets whose currency codes don't map 1:1 to country codes.
  Future<List<RemoteMerchantKeyword>> getAll() async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM remote_merchant_keywords
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY priority DESC;
      ''',
    ).get();
    return rows
        .map((r) => RemoteMerchantKeyword(
              id: r.read<String>('id'),
              keyword: r.read<String>('keyword'),
              categoryKey: r.read<String>('category_key'),
              language: r.read<String>('language'),
              countryCode: r.read<String>('country_code'),
              priority: r.read<int>('priority'),
              isActive: r.read<int>('is_active') != 0,
              isDeleted: r.read<int>('is_deleted') != 0,
              updatedAt: r.read<String>('updated_at'),
              logoUrl: r.readNullable<String>('logo_url'),
            ))
        .toList();
  }

  Future<bool> isEmpty() async {
    final rows = await _db
        .customSelect(
          'SELECT 1 FROM remote_merchant_keywords WHERE is_active = 1 AND is_deleted = 0 LIMIT 1;',
        )
        .get();
    return rows.isEmpty;
  }
}

/// A canonical merchant, as published by the server.
///
/// This is the ONLY cross-user merchant identity in the app. The local
/// `merchants` table is device-local and normalization-derived — two users who
/// shop at the same place get different local ids — so it can never be used to
/// tie a coupon to a merchant.
class RemoteCatalogMerchant {
  const RemoteCatalogMerchant({
    required this.id,
    required this.slug,
    required this.nameAr,
    required this.countryCodes,
    required this.isActive,
    required this.isDeleted,
    required this.updatedVersion,
    this.nameEn,
    this.primaryDomain,
    this.logoUrl,
    this.defaultDisplayCategoryKey,
  });

  final String id;
  final String slug;
  final String nameAr;
  final String? nameEn;
  final String? primaryDomain;
  final String? logoUrl;
  final String? defaultDisplayCategoryKey;

  /// Empty means global, matching `coupons.country_codes`.
  final List<String> countryCodes;
  final bool isActive;
  final bool isDeleted;
  final int updatedVersion;

  static RemoteCatalogMerchant fromJson(Map<String, Object?> json) {
    return RemoteCatalogMerchant(
      id: json['id'] as String,
      slug: json['slug'] as String,
      nameAr: json['name_ar'] as String,
      nameEn: json['name_en'] as String?,
      primaryDomain: json['primary_domain'] as String?,
      logoUrl: json['logo_url'] as String? ?? json['logo_path'] as String?,
      defaultDisplayCategoryKey: json['default_display_category_key'] as String?,
      countryCodes: _stringList(json['country_codes']),
      isActive: _boolFromJson(json['is_active'], defaultValue: true),
      isDeleted: _boolFromJson(json['is_deleted']),
      updatedVersion: (json['updated_version'] as num?)?.toInt() ?? 0,
    );
  }
}

class RemoteCatalogMerchantsDao {
  const RemoteCatalogMerchantsDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteCatalogMerchant> merchants) async {
    final syncedAt = DateTime.now().toUtc().toIso8601String();
    for (final m in merchants) {
      await _db.customInsert(
        '''
          INSERT INTO remote_catalog_merchants(
            id, slug, name_ar, name_en, primary_domain, logo_url,
            default_display_category_key, country_codes_json,
            is_active, is_deleted, updated_version, synced_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            slug = excluded.slug,
            name_ar = excluded.name_ar,
            name_en = excluded.name_en,
            primary_domain = excluded.primary_domain,
            logo_url = excluded.logo_url,
            default_display_category_key = excluded.default_display_category_key,
            country_codes_json = excluded.country_codes_json,
            is_active = excluded.is_active,
            is_deleted = excluded.is_deleted,
            updated_version = excluded.updated_version,
            synced_at = excluded.synced_at;
        ''',
        variables: [
          Variable.withString(m.id),
          Variable.withString(m.slug),
          Variable.withString(m.nameAr),
          if (m.nameEn == null) const Variable<String>(null) else Variable.withString(m.nameEn!),
          if (m.primaryDomain == null) const Variable<String>(null) else Variable.withString(m.primaryDomain!),
          if (m.logoUrl == null) const Variable<String>(null) else Variable.withString(m.logoUrl!),
          if (m.defaultDisplayCategoryKey == null)
            const Variable<String>(null)
          else
            Variable.withString(m.defaultDisplayCategoryKey!),
          Variable.withString(jsonEncode(m.countryCodes)),
          Variable.withInt(m.isActive ? 1 : 0),
          Variable.withInt(m.isDeleted ? 1 : 0),
          Variable.withInt(m.updatedVersion),
          Variable.withString(syncedAt),
        ],
      );
    }
  }

  /// Tombstones, never row removal: a device that only ever applies inserts
  /// would keep a withdrawn merchant forever.
  Future<void> markDeleted(List<String> ids) async {
    for (final id in ids) {
      await _db.customUpdate(
        'UPDATE remote_catalog_merchants SET is_deleted = 1, is_active = 0 WHERE id = ?;',
        variables: [Variable.withString(id)],
      );
    }
  }

  Future<List<RemoteCatalogMerchant>> getAll() async {
    final rows = await _db.customSelect(
      'SELECT * FROM remote_catalog_merchants '
      'WHERE is_active = 1 AND is_deleted = 0 ORDER BY slug;',
    ).get();
    return rows.map(_fromRow).toList();
  }

  Future<RemoteCatalogMerchant?> byId(String id) async {
    final rows = await _db.customSelect(
      'SELECT * FROM remote_catalog_merchants WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(id)],
    ).get();
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static RemoteCatalogMerchant _fromRow(QueryRow r) => RemoteCatalogMerchant(
        id: r.read<String>('id'),
        slug: r.read<String>('slug'),
        nameAr: r.read<String>('name_ar'),
        nameEn: r.readNullable<String>('name_en'),
        primaryDomain: r.readNullable<String>('primary_domain'),
        logoUrl: r.readNullable<String>('logo_url'),
        defaultDisplayCategoryKey:
            r.readNullable<String>('default_display_category_key'),
        countryCodes: _jsonStringList(r.read<String>('country_codes_json')),
        isActive: r.read<int>('is_active') != 0,
        isDeleted: r.read<int>('is_deleted') != 0,
        updatedVersion: r.read<int>('updated_version'),
      );
}

/// A reviewed alias: one exact lookup key that resolves to one merchant.
///
/// `aliasNormalized` is produced by `merchant_alias_key_v1` — on the SERVER, as
/// a generated column. The device never computes a key for storage, only for a
/// lookup, so a client-side key bug can cause a miss but can never corrupt the
/// catalog.
class RemoteMerchantAlias {
  const RemoteMerchantAlias({
    required this.id,
    required this.merchantId,
    required this.aliasNormalized,
    required this.aliasKind,
    required this.priority,
    required this.keyVersion,
    required this.isActive,
    required this.isDeleted,
    required this.updatedVersion,
    this.countryCode,
  });

  final String id;
  final String merchantId;
  final String aliasNormalized;

  /// `name` or `domain` — two different key contracts, never interchangeable.
  final String aliasKind;

  /// NULL means global. A country-scoped row outranks a global one ONLY on
  /// merchant-location evidence; see MerchantLookupPipeline.
  final String? countryCode;
  final int priority;
  final int keyVersion;
  final bool isActive;
  final bool isDeleted;
  final int updatedVersion;

  static RemoteMerchantAlias fromJson(Map<String, Object?> json) {
    return RemoteMerchantAlias(
      id: json['id'] as String,
      merchantId: json['merchant_id'] as String,
      aliasNormalized: json['alias_normalized'] as String,
      aliasKind: (json['alias_kind'] as String?) ?? 'name',
      countryCode: json['country_code'] as String?,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      keyVersion: (json['key_version'] as num?)?.toInt() ?? 1,
      isActive: _boolFromJson(json['is_active'], defaultValue: true),
      isDeleted: _boolFromJson(json['is_deleted']),
      updatedVersion: (json['updated_version'] as num?)?.toInt() ?? 0,
    );
  }
}

class RemoteMerchantAliasesDao {
  const RemoteMerchantAliasesDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteMerchantAlias> aliases) async {
    final syncedAt = DateTime.now().toUtc().toIso8601String();
    for (final a in aliases) {
      // A key this build cannot interpret is not stored. The alternative is a
      // row that looks resolvable and is not, which is worse than absent: the
      // resolver would abstain either way, but a stored future-version key would
      // also survive a downgrade and confuse the next investigation.
      if (a.keyVersion != 1) continue;
      await _db.customInsert(
        '''
          INSERT INTO remote_merchant_aliases(
            id, merchant_id, alias_normalized, alias_kind, country_code,
            priority, key_version, is_active, is_deleted, updated_version, synced_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            merchant_id = excluded.merchant_id,
            alias_normalized = excluded.alias_normalized,
            alias_kind = excluded.alias_kind,
            country_code = excluded.country_code,
            priority = excluded.priority,
            key_version = excluded.key_version,
            is_active = excluded.is_active,
            is_deleted = excluded.is_deleted,
            updated_version = excluded.updated_version,
            synced_at = excluded.synced_at;
        ''',
        variables: [
          Variable.withString(a.id),
          Variable.withString(a.merchantId),
          Variable.withString(a.aliasNormalized),
          Variable.withString(a.aliasKind),
          if (a.countryCode == null) const Variable<String>(null) else Variable.withString(a.countryCode!),
          Variable.withInt(a.priority),
          Variable.withInt(a.keyVersion),
          Variable.withInt(a.isActive ? 1 : 0),
          Variable.withInt(a.isDeleted ? 1 : 0),
          Variable.withInt(a.updatedVersion),
          Variable.withString(syncedAt),
        ],
      );
    }
  }

  Future<void> markDeleted(List<String> ids) async {
    for (final id in ids) {
      await _db.customUpdate(
        'UPDATE remote_merchant_aliases SET is_deleted = 1, is_active = 0 WHERE id = ?;',
        variables: [Variable.withString(id)],
      );
    }
  }

  /// Every candidate for one exact key. More than one row is possible and
  /// legitimate — a global row and a country row may point at different
  /// merchants — so the caller decides, and abstains when it cannot.
  Future<List<RemoteMerchantAlias>> candidatesFor(
    String aliasNormalized,
    String aliasKind,
  ) async {
    if (aliasNormalized.isEmpty) return const [];
    final rows = await _db.customSelect(
      '''
        SELECT * FROM remote_merchant_aliases
        WHERE alias_normalized = ? AND alias_kind = ?
          AND is_active = 1 AND is_deleted = 0 AND key_version = 1
        ORDER BY priority DESC;
      ''',
      variables: [
        Variable.withString(aliasNormalized),
        Variable.withString(aliasKind),
      ],
    ).get();
    return rows.map(_fromRow).toList();
  }

  Future<int> count() async {
    final rows = await _db
        .customSelect('SELECT COUNT(*) AS c FROM remote_merchant_aliases '
            'WHERE is_active = 1 AND is_deleted = 0;')
        .get();
    return rows.first.read<int>('c');
  }

  static RemoteMerchantAlias _fromRow(QueryRow r) => RemoteMerchantAlias(
        id: r.read<String>('id'),
        merchantId: r.read<String>('merchant_id'),
        aliasNormalized: r.read<String>('alias_normalized'),
        aliasKind: r.read<String>('alias_kind'),
        countryCode: r.readNullable<String>('country_code'),
        priority: r.read<int>('priority'),
        keyVersion: r.read<int>('key_version'),
        isActive: r.read<int>('is_active') != 0,
        isDeleted: r.read<int>('is_deleted') != 0,
        updatedVersion: r.read<int>('updated_version'),
      );
}

class PendingMerchantFeedbackDao {
  const PendingMerchantFeedbackDao(this._db);

  final AppDatabase _db;

  Future<void> record(String normalizedKeyword) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.customInsert(
      '''
        INSERT INTO pending_merchant_feedback(normalized_keyword, seen_count, last_seen_at)
        VALUES (?, 1, ?)
        ON CONFLICT(normalized_keyword) DO UPDATE SET
          seen_count = seen_count + 1,
          last_seen_at = excluded.last_seen_at;
      ''',
      variables: [
        Variable.withString(normalizedKeyword),
        Variable.withString(now),
      ],
    );
  }

  Future<List<String>> drainAll() async {
    final rows = await _db
        .customSelect(
          'SELECT normalized_keyword FROM pending_merchant_feedback;',
        )
        .get();
    final keywords =
        rows.map((r) => r.read<String>('normalized_keyword')).toList();
    if (keywords.isNotEmpty) {
      await _db.customStatement('DELETE FROM pending_merchant_feedback;');
    }
    return keywords;
  }

  Future<int> count() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS total FROM pending_merchant_feedback;',
        )
        .getSingle();
    return row.read<int>('total');
  }
}

Variable<String> _nullableString(String? value) {
  return value == null
      ? const Variable<String>(null)
      : Variable.withString(value);
}

String? _optionalString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

DateTime _dateTimeFromJson(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return DateTime.now().toUtc();
  return DateTime.parse(text).toUtc();
}

bool _boolFromJson(Object? value, {bool defaultValue = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return defaultValue;
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return value.map((item) => item.toString()).toList(growable: false);
  }
  if (value is String) {
    return _jsonStringList(value);
  }
  return const [];
}

List<String> _jsonStringList(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! List) return const [];
  return decoded.map((item) => item.toString()).toList(growable: false);
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  if (value is String) return _jsonObjectMap(value);
  return const {};
}

Map<String, Object?> _jsonObjectMap(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map) return const {};
  return decoded.map((key, val) => MapEntry(key.toString(), val));
}

// ─────────────────────────────────────────────────────────
// Feature Flags
// ─────────────────────────────────────────────────────────

class RemoteFeatureFlag {
  const RemoteFeatureFlag({
    required this.key,
    required this.valueType,
    required this.value,
    required this.rolloutPercent,
    required this.targetCountries,
    required this.isActive,
    required this.syncedAt,
  });

  final String key;
  final String valueType;
  final String value;
  final int rolloutPercent;
  final List<String> targetCountries;
  final bool isActive;
  final DateTime syncedAt;

  static RemoteFeatureFlag fromJson(Map<String, Object?> json) {
    return RemoteFeatureFlag(
      key: json['key'].toString(),
      valueType: json['value_type'].toString(),
      value: json['value'].toString(),
      rolloutPercent: (json['rollout_percent'] as num?)?.toInt() ?? 100,
      targetCountries: _stringList(json['target_countries']),
      isActive: json['is_active'] as bool? ?? true,
      syncedAt: DateTime.now().toUtc(),
    );
  }
}

class RemoteFeatureFlagsDao {
  RemoteFeatureFlagsDao(this._db);

  final AppDatabase _db;

  Future<void> replaceAll(List<RemoteFeatureFlag> flags) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM remote_feature_flags;');
      for (final flag in flags) {
        await _db.customInsert(
          '''
            INSERT INTO remote_feature_flags(
              key, value_type, value, rollout_percent, target_countries,
              is_active, synced_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
              value_type = excluded.value_type,
              value = excluded.value,
              rollout_percent = excluded.rollout_percent,
              target_countries = excluded.target_countries,
              is_active = excluded.is_active,
              synced_at = excluded.synced_at;
          ''',
          variables: [
            Variable.withString(flag.key),
            Variable.withString(flag.valueType),
            Variable.withString(flag.value),
            Variable.withInt(flag.rolloutPercent),
            Variable.withString(jsonEncode(flag.targetCountries)),
            Variable.withInt(boolToSql(flag.isActive)),
            Variable.withString(now),
          ],
        );
      }
    });
  }

  Future<List<RemoteFeatureFlag>> getAllActiveFlags() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM remote_feature_flags WHERE is_active = 1;',
        )
        .get();
    return rows.map(_flagFromRow).toList();
  }

  RemoteFeatureFlag _flagFromRow(QueryRow row) {
    return RemoteFeatureFlag(
      key: row.read<String>('key'),
      valueType: row.read<String>('value_type'),
      value: row.read<String>('value'),
      rolloutPercent: row.read<int>('rollout_percent'),
      targetCountries: _jsonStringList(row.read<String>('target_countries')),
      isActive: sqlToBool(row.read<int>('is_active')),
      syncedAt: dateTimeFromSql(row.read<String>('synced_at')),
    );
  }
}

// ─────────────────────────────────────────────────────────
// Announcements
// ─────────────────────────────────────────────────────────

class RemoteAnnouncement {
  const RemoteAnnouncement({
    required this.id,
    required this.titleAr,
    required this.titleEn,
    required this.bodyAr,
    required this.bodyEn,
    required this.severity,
    required this.minAppVersion,
    required this.maxAppVersion,
    required this.actionLabelAr,
    required this.actionLabelEn,
    required this.actionUrl,
    required this.validFrom,
    required this.validUntil,
    required this.isDismissible,
    required this.priority,
    required this.isDismissed,
    required this.dismissedAt,
    required this.syncedAt,
  });

  final String id;
  final String titleAr;
  final String titleEn;
  final String? bodyAr;
  final String? bodyEn;
  /// 'info'|'warning'|'maintenance'|'force_update'|'update_available'|
  /// 'release_notes'. Only 'force_update' blocks the app.
  final String severity;
  final String? minAppVersion;
  final String? maxAppVersion;
  final String? actionLabelAr;
  final String? actionLabelEn;
  final String? actionUrl;
  final DateTime validFrom;
  final DateTime? validUntil;
  final bool isDismissible;
  final int priority;
  final bool isDismissed;
  final DateTime? dismissedAt;
  final DateTime syncedAt;

  bool get isForceUpdate => severity == 'force_update';

  /// A dismissible "a newer version is in the App Store" banner. Never blocks.
  bool get isUpdateAvailable => severity == 'update_available';

  /// Server notes for the What's new page; never shown as a banner.
  bool get isReleaseNotes => severity == 'release_notes';

  /// Whether [version] lies inside [minAppVersion]..[maxAppVersion]
  /// (inclusive, same rule as the catalog-announcements function). The server
  /// already filters by the X-App-Version header; this re-check stops a row
  /// cached before an app update from showing to the updated app.
  bool targetsVersion(String version) {
    final min = minAppVersion;
    final max = maxAppVersion;
    if (min != null && min.isNotEmpty && compareAppVersions(version, min) < 0) {
      return false;
    }
    if (max != null && max.isNotEmpty && compareAppVersions(version, max) > 0) {
      return false;
    }
    return true;
  }

  static RemoteAnnouncement fromJson(Map<String, Object?> json) {
    return RemoteAnnouncement(
      id: json['id'].toString(),
      titleAr: json['title_ar'].toString(),
      titleEn: json['title_en'].toString(),
      bodyAr: _optionalString(json['body_ar']),
      bodyEn: _optionalString(json['body_en']),
      severity: json['severity'].toString(),
      minAppVersion: _optionalString(json['min_app_version']),
      maxAppVersion: _optionalString(json['max_app_version']),
      actionLabelAr: _optionalString(json['action_label_ar']),
      actionLabelEn: _optionalString(json['action_label_en']),
      actionUrl: _optionalString(json['action_url']),
      validFrom: _dateTimeFromJson(json['valid_from']),
      validUntil: json['valid_until'] != null
          ? _dateTimeFromJson(json['valid_until'])
          : null,
      isDismissible: json['is_dismissible'] as bool? ?? true,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      isDismissed: false,
      dismissedAt: null,
      syncedAt: DateTime.now().toUtc(),
    );
  }
}

/// Compares `major.minor.patch` versions numerically (missing or non-numeric
/// parts count as 0), like `compareSemver` in catalog-announcements.
int compareAppVersions(String a, String b) {
  List<int> parts(String v) {
    final p = v.replaceAll(RegExp(r'[^0-9.]'), '').split('.');
    return [
      for (var i = 0; i < 3; i++) i < p.length ? int.tryParse(p[i]) ?? 0 : 0,
    ];
  }

  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return 0;
}

class RemoteAnnouncementsDao {
  RemoteAnnouncementsDao(this._db);

  final AppDatabase _db;

  /// Full replace from server, preserving local is_dismissed state.
  Future<void> replaceAll(List<RemoteAnnouncement> announcements) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.transaction(() async {
      // Collect currently dismissed IDs before wiping.
      final dismissedRows = await _db
          .customSelect(
            'SELECT id FROM remote_announcements WHERE is_dismissed = 1;',
          )
          .get();
      final dismissedIds =
          dismissedRows.map((r) => r.read<String>('id')).toSet();

      await _db.customStatement('DELETE FROM remote_announcements;');

      for (final a in announcements) {
        final wasDismissed = dismissedIds.contains(a.id);
        await _db.customInsert(
          '''
            INSERT INTO remote_announcements(
              id, title_ar, title_en, body_ar, body_en, severity,
              min_app_version, max_app_version, action_label_ar,
              action_label_en, action_url, valid_from, valid_until,
              is_dismissible, priority, is_dismissed, dismissed_at, synced_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?);
          ''',
          variables: [
            Variable.withString(a.id),
            Variable.withString(a.titleAr),
            Variable.withString(a.titleEn),
            _nullableString(a.bodyAr),
            _nullableString(a.bodyEn),
            Variable.withString(a.severity),
            _nullableString(a.minAppVersion),
            _nullableString(a.maxAppVersion),
            _nullableString(a.actionLabelAr),
            _nullableString(a.actionLabelEn),
            _nullableString(a.actionUrl),
            Variable.withString(dateTimeToSql(a.validFrom)),
            a.validUntil != null
                ? Variable.withString(dateTimeToSql(a.validUntil!))
                : const Variable<String>(null),
            Variable.withInt(boolToSql(a.isDismissible)),
            Variable.withInt(a.priority),
            Variable.withInt(boolToSql(wasDismissed)),
            Variable.withString(now),
          ],
        );
      }
    });
  }

  Future<List<RemoteAnnouncement>> getActiveNonDismissed() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final rows = await _db.customSelect(
      '''
        SELECT * FROM remote_announcements
        WHERE is_dismissed = 0
          AND valid_from <= ?
          AND (valid_until IS NULL OR valid_until >= ?)
        ORDER BY priority DESC, valid_from ASC;
      ''',
      variables: [Variable.withString(now), Variable.withString(now)],
    ).get();
    return rows.map(_announcementFromRow).toList();
  }

  Future<void> setDismissed(String id) async {
    await _db.customUpdate(
      '''
        UPDATE remote_announcements
        SET is_dismissed = 1, dismissed_at = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        Variable.withString(id),
      ],
    );
  }

  RemoteAnnouncement _announcementFromRow(QueryRow row) {
    final validUntilRaw = row.readNullable<String>('valid_until');
    final dismissedAtRaw = row.readNullable<String>('dismissed_at');
    return RemoteAnnouncement(
      id: row.read<String>('id'),
      titleAr: row.read<String>('title_ar'),
      titleEn: row.read<String>('title_en'),
      bodyAr: row.readNullable<String>('body_ar'),
      bodyEn: row.readNullable<String>('body_en'),
      severity: row.read<String>('severity'),
      minAppVersion: row.readNullable<String>('min_app_version'),
      maxAppVersion: row.readNullable<String>('max_app_version'),
      actionLabelAr: row.readNullable<String>('action_label_ar'),
      actionLabelEn: row.readNullable<String>('action_label_en'),
      actionUrl: row.readNullable<String>('action_url'),
      validFrom: dateTimeFromSql(row.read<String>('valid_from')),
      validUntil: validUntilRaw != null ? dateTimeFromSql(validUntilRaw) : null,
      isDismissible: sqlToBool(row.read<int>('is_dismissible')),
      priority: row.read<int>('priority'),
      isDismissed: sqlToBool(row.read<int>('is_dismissed')),
      dismissedAt:
          dismissedAtRaw != null ? dateTimeFromSql(dismissedAtRaw) : null,
      syncedAt: dateTimeFromSql(row.read<String>('synced_at')),
    );
  }
}

// Growth campaigns
// ─────────────────────────────────────────────────────────

class RemoteGrowthCampaign {
  const RemoteGrowthCampaign({
    required this.id,
    required this.titleAr,
    required this.titleEn,
    required this.bodyAr,
    required this.bodyEn,
    required this.type,
    required this.targetSegment,
    required this.actionLabelAr,
    required this.actionLabelEn,
    required this.actionRoute,
    required this.actionUrl,
    required this.validFrom,
    required this.validUntil,
    required this.maxImpressions,
    required this.cooldownHours,
    required this.isDismissible,
    required this.oncePerUser,
    required this.priority,
    required this.isActive,
    required this.syncedAt,
  });

  final String id;
  final String titleAr;
  final String titleEn;
  final String? bodyAr;
  final String? bodyEn;
  final String type;
  final String targetSegment;
  final String? actionLabelAr;
  final String? actionLabelEn;
  final String? actionRoute;
  final String? actionUrl;
  final DateTime validFrom;
  final DateTime? validUntil;
  final int? maxImpressions;
  final int cooldownHours;
  final bool isDismissible;
  final bool oncePerUser;
  final int priority;
  final bool isActive;
  final DateTime syncedAt;

  static RemoteGrowthCampaign fromJson(Map<String, Object?> json) {
    return RemoteGrowthCampaign(
      id: json['id'].toString(),
      titleAr: json['title_ar'].toString(),
      titleEn: json['title_en'].toString(),
      bodyAr: _optionalString(json['body_ar']),
      bodyEn: _optionalString(json['body_en']),
      type: json['type'].toString(),
      targetSegment: json['target_segment'].toString(),
      actionLabelAr: _optionalString(json['action_label_ar']),
      actionLabelEn: _optionalString(json['action_label_en']),
      actionRoute: _optionalString(json['action_route']),
      actionUrl: _optionalString(json['action_url']),
      validFrom: _dateTimeFromJson(json['valid_from']),
      validUntil: json['valid_until'] != null
          ? _dateTimeFromJson(json['valid_until'])
          : null,
      maxImpressions: (json['max_impressions'] as num?)?.toInt(),
      cooldownHours: (json['cooldown_hours'] as num?)?.toInt() ?? 24,
      isDismissible: json['is_dismissible'] as bool? ?? true,
      oncePerUser: json['once_per_user'] as bool? ?? false,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      isActive: json['is_active'] as bool? ?? true,
      syncedAt: DateTime.now().toUtc(),
    );
  }
}

class RemoteGrowthCampaignsDao {
  RemoteGrowthCampaignsDao(this._db);

  final AppDatabase _db;

  Future<void> replaceAll(List<RemoteGrowthCampaign> campaigns) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM remote_growth_campaigns;');
      for (final c in campaigns) {
        await _db.customInsert(
          '''
            INSERT INTO remote_growth_campaigns(
              id, title_ar, title_en, body_ar, body_en, type, target_segment,
              action_label_ar, action_label_en, action_route, action_url,
              valid_from, valid_until, max_impressions, cooldown_hours,
              is_dismissible, once_per_user, priority, is_active, synced_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString(c.id),
            Variable.withString(c.titleAr),
            Variable.withString(c.titleEn),
            _nullableString(c.bodyAr),
            _nullableString(c.bodyEn),
            Variable.withString(c.type),
            Variable.withString(c.targetSegment),
            _nullableString(c.actionLabelAr),
            _nullableString(c.actionLabelEn),
            _nullableString(c.actionRoute),
            _nullableString(c.actionUrl),
            Variable.withString(dateTimeToSql(c.validFrom)),
            c.validUntil != null
                ? Variable.withString(dateTimeToSql(c.validUntil!))
                : const Variable<String>(null),
            c.maxImpressions != null
                ? Variable.withInt(c.maxImpressions!)
                : const Variable<int>(null),
            Variable.withInt(c.cooldownHours),
            Variable.withInt(boolToSql(c.isDismissible)),
            Variable.withInt(boolToSql(c.oncePerUser)),
            Variable.withInt(c.priority),
            Variable.withInt(boolToSql(c.isActive)),
            Variable.withString(now),
          ],
        );
      }
    });
  }

  Future<List<RemoteGrowthCampaign>> getActiveByType(String type) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final rows = await _db.customSelect(
      '''
        SELECT * FROM remote_growth_campaigns
        WHERE is_active = 1
          AND type = ?
          AND valid_from <= ?
          AND (valid_until IS NULL OR valid_until >= ?)
        ORDER BY priority DESC, valid_from ASC;
      ''',
      variables: [
        Variable.withString(type),
        Variable.withString(now),
        Variable.withString(now),
      ],
    ).get();
    return rows.map(_campaignFromRow).toList();
  }

  RemoteGrowthCampaign _campaignFromRow(QueryRow row) {
    final validUntilRaw = row.readNullable<String>('valid_until');
    return RemoteGrowthCampaign(
      id: row.read<String>('id'),
      titleAr: row.read<String>('title_ar'),
      titleEn: row.read<String>('title_en'),
      bodyAr: row.readNullable<String>('body_ar'),
      bodyEn: row.readNullable<String>('body_en'),
      type: row.read<String>('type'),
      targetSegment: row.read<String>('target_segment'),
      actionLabelAr: row.readNullable<String>('action_label_ar'),
      actionLabelEn: row.readNullable<String>('action_label_en'),
      actionRoute: row.readNullable<String>('action_route'),
      actionUrl: row.readNullable<String>('action_url'),
      validFrom: dateTimeFromSql(row.read<String>('valid_from')),
      validUntil: validUntilRaw != null ? dateTimeFromSql(validUntilRaw) : null,
      maxImpressions: row.readNullable<int>('max_impressions'),
      cooldownHours: row.read<int>('cooldown_hours'),
      isDismissible: sqlToBool(row.read<int>('is_dismissible')),
      oncePerUser: sqlToBool(row.read<int>('once_per_user')),
      priority: row.read<int>('priority'),
      isActive: sqlToBool(row.read<int>('is_active')),
      syncedAt: dateTimeFromSql(row.read<String>('synced_at')),
    );
  }
}


/// MALI-COUPONS (Phase C4) — the Offers/Coupons catalog cache (schema v31).
///
/// Pure refetchable server catalog. [replaceAll] is the ONLY writer and is
/// atomic: a snapshot either lands whole or leaves the previous cache intact.
class RemoteCouponsDao {
  const RemoteCouponsDao(this._db);

  final AppDatabase _db;

  /// Atomically swap the cached catalog for [offers].
  ///
  /// Runs inside ONE transaction: the delete and every insert commit together,
  /// so a decode/insert failure rolls back and the previous snapshot survives
  /// (there is no window where the catalog is half-old/half-new). An EMPTY list
  /// is a legitimate snapshot — it clears the cache — and is never confused with
  /// a failed sync, which does not call this method at all.
  Future<void> replaceAll(List<CouponOffer> offers) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM remote_coupons;');
      for (final offer in offers) {
        await _db.customInsert(
          '''
          INSERT INTO remote_coupons(
            id, slug, partner_name, title_ar, title_en, description_ar,
            description_en, redemption_type, code, partner_url,
            display_category_key, display_category_label_ar,
            display_category_label_en, tags_json, spend_hints_json,
            country_codes_json, accent_hex, image_url, featured, priority,
            valid_from, valid_until, terms_ar, synced_at,
            merchant_id, merchant_slug, merchant_name_ar, merchant_name_en,
            benefit_type, discount_bps, fixed_amount_minor, min_spend_minor,
            max_saving_minor, benefit_currency, source, verification_state
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString(offer.id),
            Variable.withString(offer.slug),
            Variable.withString(offer.partnerName),
            Variable.withString(offer.titleAr),
            Variable<String>(offer.titleEn),
            Variable.withString(offer.descriptionAr),
            Variable<String>(offer.descriptionEn),
            Variable.withString(offer.redemptionType.name),
            Variable<String>(offer.code),
            Variable<String>(offer.partnerUrl),
            Variable.withString(offer.category.key),
            Variable.withString(offer.category.labelAr),
            Variable<String>(offer.category.labelEn),
            Variable.withString(offer.tagsJson),
            Variable.withString(offer.spendHintsJson),
            Variable.withString(offer.countryCodesJson),
            Variable<String>(offer.accentHex),
            Variable<String>(offer.imageUrl),
            Variable.withInt(offer.featured ? 1 : 0),
            Variable.withInt(offer.priority),
            Variable.withString(dateTimeToSql(offer.validFrom.toUtc())),
            Variable<String>(offer.validUntil == null
                ? null
                : dateTimeToSql(offer.validUntil!.toUtc())),
            Variable<String>(offer.termsAr),
            Variable.withString(now),
            // Phase 1. Every one is nullable and a null round-trips as a null:
            // an offer whose value is prose only must stay prose only, because
            // the savings layer keys off exactly this absence to abstain.
            Variable<String>(offer.merchantId),
            Variable<String>(offer.merchantSlug),
            Variable<String>(offer.merchantNameAr),
            Variable<String>(offer.merchantNameEn),
            Variable<String>(offer.benefitType),
            Variable<int>(offer.discountBps),
            Variable<int>(offer.fixedAmountMinor),
            Variable<int>(offer.minSpendMinor),
            Variable<int>(offer.maxSavingMinor),
            Variable<String>(offer.benefitCurrency),
            Variable.withString(offer.source),
            Variable.withString(offer.verificationState),
          ],
        );
      }
    });
  }

  /// Read the cached catalog as typed domain models (widgets never see JSON).
  Future<List<CouponOffer>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM remote_coupons '
          'ORDER BY featured DESC, priority DESC, valid_from DESC, id ASC;',
        )
        .get();
    return rows.map(_fromRow).whereType<CouponOffer>().toList();
  }

  Future<int> count() async =>
      (await _db.customSelect('SELECT COUNT(*) AS n FROM remote_coupons;').getSingle())
          .read<int>('n');

  static CouponOffer? _fromRow(QueryRow row) {
    final type = CouponRedemptionType.tryParse(row.read<String>('redemption_type'));
    final validFrom = DateTime.tryParse(row.read<String>('valid_from'))?.toUtc();
    if (type == null || validFrom == null) return null;
    final until = row.readNullable<String>('valid_until');

    List<Object?> decodeList(String column) {
      final raw = row.read<String>(column);
      try {
        final decoded = jsonDecode(raw);
        return decoded is List ? decoded : const <Object?>[];
      } catch (_) {
        return const <Object?>[];
      }
    }

    return CouponOffer(
      id: row.read<String>('id'),
      slug: row.read<String>('slug'),
      partnerName: row.read<String>('partner_name'),
      titleAr: row.read<String>('title_ar'),
      titleEn: row.readNullable<String>('title_en'),
      descriptionAr: row.read<String>('description_ar'),
      descriptionEn: row.readNullable<String>('description_en'),
      redemptionType: type,
      code: row.readNullable<String>('code'),
      partnerUrl: row.readNullable<String>('partner_url'),
      category: CouponCategory(
        key: row.read<String>('display_category_key'),
        labelAr: row.read<String>('display_category_label_ar'),
        labelEn: row.readNullable<String>('display_category_label_en'),
      ),
      tags: decodeList('tags_json')
          .map(CouponTag.tryParse)
          .whereType<CouponTag>()
          .toList(),
      spendHintCategoryKeys:
          decodeList('spend_hints_json').whereType<String>().toList(),
      countryCodes: decodeList('country_codes_json').whereType<String>().toList(),
      accentHex: row.readNullable<String>('accent_hex'),
      imageUrl: row.readNullable<String>('image_url'),
      featured: row.read<int>('featured') == 1,
      priority: row.read<int>('priority'),
      validFrom: validFrom,
      validUntil: until == null ? null : DateTime.tryParse(until)?.toUtc(),
      termsAr: row.readNullable<String>('terms_ar'),
      // Phase 1. Read defensively: a cache row written before v34 has these
      // columns (the migration adds them) but they are NULL, and a row written
      // by a build that predates this reader must still decode rather than
      // drop the offer.
      merchantId: row.readNullable<String>('merchant_id'),
      merchantSlug: row.readNullable<String>('merchant_slug'),
      merchantNameAr: row.readNullable<String>('merchant_name_ar'),
      merchantNameEn: row.readNullable<String>('merchant_name_en'),
      benefitType: row.readNullable<String>('benefit_type'),
      discountBps: row.readNullable<int>('discount_bps'),
      fixedAmountMinor: row.readNullable<int>('fixed_amount_minor'),
      minSpendMinor: row.readNullable<int>('min_spend_minor'),
      maxSavingMinor: row.readNullable<int>('max_saving_minor'),
      benefitCurrency: row.readNullable<String>('benefit_currency'),
      source: row.readNullable<String>('source') ?? 'manual',
      verificationState:
          row.readNullable<String>('verification_state') ?? 'unverified',
    );
  }
}
