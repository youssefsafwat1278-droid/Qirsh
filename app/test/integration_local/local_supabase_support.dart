// Support for the LOCAL-ONLY end-to-end sync proof (tag `local-supabase`).
//
// Everything here talks ONLY to the URL in LOCAL_SUPABASE_URL (a developer's
// isolated local Supabase). Keys come from the environment and are never
// logged. The harness refuses to run against a non-loopback host.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Environment contract (all set by the runner script, never committed).
class LocalEnv {
  LocalEnv._(this.url, this.anonKey, this.serviceKey, this.dbUrl, this.jwtSecret);

  final String url;
  final String anonKey;
  final String serviceKey;
  final String dbUrl;
  final String jwtSecret;

  static String? get _url => Platform.environment['LOCAL_SUPABASE_URL'];

  /// True only when the runner opted in.
  static bool get enabled => (_url ?? '').isNotEmpty;

  static LocalEnv load() {
    final e = Platform.environment;
    final url = e['LOCAL_SUPABASE_URL'] ?? '';
    final host = Uri.parse(url).host;
    if (host != '127.0.0.1' && host != 'localhost') {
      throw StateError('LOCAL_SUPABASE_URL must be loopback, got host=$host');
    }
    String need(String k) {
      final v = e[k] ?? '';
      if (v.isEmpty) throw StateError('$k is required');
      return v;
    }

    return LocalEnv._(
      url,
      need('LOCAL_SUPABASE_ANON_KEY'),
      need('LOCAL_SUPABASE_SERVICE_ROLE_KEY'),
      need('LOCAL_SUPABASE_DB_URL'),
      e['LOCAL_SUPABASE_JWT_SECRET'] ?? '',
    );
  }
}

/// The http client handed to `Supabase.initialize`. It counts every request and
/// lets a scenario inject real-world conditions without touching production
/// code: a dead port, a rejected bearer token, a failing endpoint.
class ProbeClient extends http.BaseClient {
  ProbeClient(this._inner);

  final http.Client _inner;
  final List<String> log = [];

  /// Re-route to a closed loopback port: a REAL connection-refused error.
  bool offline = false;

  /// Replaces the Authorization bearer on every request when non-null.
  String? bearerOverride;

  /// When it returns true the request is not sent; a transport error is thrown.
  bool Function(http.BaseRequest)? failWhen;

  /// When it returns true the request IS delivered and executed by the server,
  /// but the response is dropped and a transport error is thrown: a LOST ACK.
  bool Function(http.BaseRequest)? lostResponseWhen;

  int get requests => log.length;
  void resetCount() => log.clear();

  int countWhere(bool Function(String entry) test) => log.where(test).length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    log.add('${request.method} ${request.url.path}');
    if (failWhen?.call(request) == true) {
      throw const SocketException('injected transport failure');
    }
    if (lostResponseWhen?.call(request) == true) {
      final res = await _inner.send(request);
      await res.stream.drain<void>();
      throw const SocketException('injected: response lost after server commit');
    }
    if (!offline && bearerOverride == null) return _inner.send(request);
    final bytes = await request.finalize().toBytes();
    final url = offline
        ? request.url.replace(host: '127.0.0.1', port: 1)
        : request.url;
    final copy = http.Request(request.method, url)
      ..bodyBytes = bytes
      ..headers.addAll(request.headers);
    if (bearerOverride != null) {
      copy.headers['Authorization'] = 'Bearer $bearerOverride';
    }
    return _inner.send(copy);
  }
}

/// Service-role view of the local stack (bypasses RLS) — the ground truth the
/// scenarios assert against. Used directly with package:http, never through the
/// app's client, so it is not counted by [ProbeClient].
class RemoteTruth {
  RemoteTruth(this.env) : _http = http.Client();

  final LocalEnv env;
  final http.Client _http;
  final List<String> createdUserIds = [];

  Map<String, String> get _svc => {
        'apikey': env.serviceKey,
        'Authorization': 'Bearer ${env.serviceKey}',
        'Content-Type': 'application/json',
      };

  /// Creates a confirmed user through the admin API; returns its uid.
  Future<({String uid, String email, String password})> createUser(
      String label) async {
    final email =
        '$label-${DateTime.now().microsecondsSinceEpoch}@proof.invalid';
    const password = 'Proof-pass-1234!';
    final res = await _http.post(
      Uri.parse('${env.url}/auth/v1/admin/users'),
      headers: _svc,
      body: jsonEncode(
          {'email': email, 'password': password, 'email_confirm': true}),
    );
    if (res.statusCode >= 300) {
      throw StateError('createUser failed: ${res.statusCode}');
    }
    final uid = (jsonDecode(res.body) as Map)['id'] as String;
    createdUserIds.add(uid);
    return (uid: uid, email: email, password: password);
  }

  /// Rows of [table] for [uid]. [select] may use PostgREST casts, e.g.
  /// `id,amount_text:amount::text`. [filter] is a raw query string suffix.
  Future<List<Map<String, dynamic>>> rows(
    String table,
    String uid, {
    String select = '*',
    String filter = '',
  }) async {
    final uri = Uri.parse(
        '${env.url}/rest/v1/$table?select=${Uri.encodeQueryComponent(select)}'
        '&user_id=eq.$uid${filter.isEmpty ? '' : '&$filter'}');
    final res = await _http.get(uri, headers: _svc);
    if (res.statusCode >= 300) {
      throw StateError('REST $table -> ${res.statusCode} ${res.body}');
    }
    return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
  }

  Future<int> count(String table, String uid, {String filter = ''}) async =>
      (await rows(table, uid, select: 'id', filter: filter)).length;

  /// Service-role PATCH (simulates "another device" writing the server row).
  Future<void> patch(String table, String id, Map<String, dynamic> body) async {
    final res = await _http.patch(
      Uri.parse('${env.url}/rest/v1/$table?id=eq.$id'),
      headers: _svc,
      body: jsonEncode(body),
    );
    if (res.statusCode >= 300) {
      throw StateError('PATCH $table -> ${res.statusCode} ${res.body}');
    }
  }

  static const _userTables = [
    'user_transactions',
    'user_plan_transaction_links',
    'user_goal_contributions',
    'user_bill_payments',
    'user_budgets',
    'user_goals',
    'user_plans',
    'user_subscriptions',
    'sender_bank_mappings',
    'user_merchant_rules',
    'user_accounts',
  ];

  /// Deletes every test row, then the users. Returns rows left behind.
  Future<int> cleanup() async {
    var left = 0;
    for (final uid in createdUserIds) {
      for (final t in _userTables) {
        await _http.delete(
          Uri.parse('${env.url}/rest/v1/$t?user_id=eq.$uid'),
          headers: _svc,
        );
      }
      await _http.delete(
        Uri.parse('${env.url}/auth/v1/admin/users/$uid'),
        headers: _svc,
      );
      for (final t in _userTables) {
        left += await count(t, uid);
      }
    }
    return left;
  }

  /// Runs a SQL file (or statement) against the local DB with psql.
  Future<String> psql({String? file, String? sql}) async {
    final args = [
      env.dbUrl,
      '-v',
      'ON_ERROR_STOP=1',
      '-At',
      if (file != null) ...['-f', file] else ...['-c', sql!],
    ];
    final r = await Process.run('psql', args);
    if (r.exitCode != 0) {
      throw StateError('psql failed: ${r.stderr}');
    }
    return (r.stdout as String).trim();
  }

  void close() => _http.close();
}

/// HS256 JWT signed with the LOCAL stack secret whose `exp` is in the past.
/// Used to prove an expired token is classified `auth`. Never leaves loopback.
String expiredLocalJwt(LocalEnv env, String uid) {
  String b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final header = b64(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
  final payload = b64(utf8.encode(jsonEncode({
    'sub': uid,
    'role': 'authenticated',
    'aud': 'authenticated',
    'iat': now - 7200,
    'exp': now - 3600,
  })));
  final sig = Hmac(sha256, utf8.encode(env.jwtSecret))
      .convert(utf8.encode('$header.$payload'));
  return '$header.$payload.${b64(sig.bytes)}';
}
