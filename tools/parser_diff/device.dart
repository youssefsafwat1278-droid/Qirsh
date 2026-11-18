// Device + effective-import leg of the parser differential harness.
// Run by run.sh as a `flutter test` from the version's own `app/` folder
// (PARSER_DIFF_ARGS = "<cases.json> <server.jsonl> <out.jsonl>"), so it
// compiles against that version's `app/lib`; run.sh writes the version shim
// `shim.dart` next to it.
//
// Device: isIgnoredMessage, then ParserEngine.parse, then the booking of
// AddTransactionUseCase (resolved direction = DirectionSignal.detect ?? type;
// own-account wording → neutral; a transfer → income if incoming else
// payment). Effective (iOS import, AI off): the meaning hold (where the
// version has one), the server row when it validates and the device does not
// contradict it (merchant passed, as CaptureImportService does); a
// contradicted row or a direction_contradiction goes to Smart Inbox (review);
// any other validation failure, or no processed server row, the device result.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/parser/direction_signal.dart';
import 'package:money_companion/engine/parser/transaction_state_cues.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'shim.dart' as shim;

bool internal(String raw) {
  final l = raw.toLowerCase();
  return ['internal transfer', 'own account', 'self transfer', 'between your accounts', 'تحويل داخلي',
    'بين حساباتك', 'بين حساباتكم', 'لحسابك الآخر', 'من حسابك إلى حسابك'].any(l.contains);
}

bool transferish(String raw) {
  final l = raw.toLowerCase();
  return ['ipn transfer', 'ipn ref', 'instapay', 'transfer sent', 'transfer received', 'outward transfer',
        'inward transfer', 'internal transfer', 'received from', 'sent to', 'انستاباي', 'تحويل', 'حوالة'].any(l.contains) ||
      (l.contains('credited by') && l.contains(' from ')) || (l.contains('debited by') && l.contains(' to '));
}

String bookOf(String type) => switch (type) {
      'income' => 'IN', 'refund' => 'IN', 'transfer' => 'NEU', 'unknown' => 'NEU', _ => 'OUT' };

Map<String, dynamic> guarded(Map<String, dynamic> Function() f) {
  try {
    return f();
  } catch (e) {
    return {'c': 'THROW', 'p': e.runtimeType.toString()};
  }
}

Map<String, dynamic> device(String raw, String? snd) => guarded(() {
      if (ParserEngine.isIgnoredMessage(raw, senderId: snd)) return {'c': 'SIL', 'p': 'ignored'};
      final r = const ParserEngine().parse(raw, senderId: snd);
      if (!r.isTransaction) {
        if (TransactionStateCues.isNotCompleted(raw)) return {'c': 'REV', 'p': 'not_completed'};
        final m = shim.meaning(raw);
        return {'c': 'REV', 'p': r.amountDetected ? (m ?? 'review') : 'drop'};
      }
      final x = r.transaction!;
      final ds = DirectionSignal.detect(raw);
      final res = ds != TxnDirection.unknown ? ds : DirectionSignal.ofType(x.type);
      final incoming = res == TxnDirection.credit;
      String t;
      if (internal(raw) || (incoming && x.type == TransactionType.withdrawal)) {
        t = 'transfer';
      } else if (x.type == TransactionType.transfer || transferish(raw)) {
        t = incoming ? 'income' : 'payment';
      } else {
        t = x.type.name;
      }
      return {'c': bookOf(t), 'p': x.type.name, 'a': x.amount, 'cur': x.currency, 'fa': x.foreignAmount, 'fcur': x.foreignCurrency};
    });

Map<String, dynamic> serverBooked(Map s, String raw) {
  var t = s['type'] as String? ?? 'unknown';
  if (t == 'transfer' && !internal(raw)) {
    if (s['dir'] == 'debit') t = 'payment';
    if (s['dir'] == 'credit') t = 'income';
  }
  return {'c': bookOf(t), 'p': 'server:${s['type']}', 'a': s['a'], 'cur': s['cur']};
}

String eff(Map s, String t, String? snd) {
  final held = shim.hold(t);
  if (held != null) return 'hold:$held';
  final reason = validateCaptureCandidate(
          candidate: CaptureCandidate(amount: (s['a'] as num?)?.toDouble(), amountText: s['at'] as String?,
              currency: s['cur'] as String?, direction: s['dir'] as String?, type: s['type'] as String?,
              merchant: s['m'] as String?, last4: s['l4'] as String?, occurredAt: s['occ'] as String?),
          text: t, receivedAt: DateTime.utc(2026, 11, 17, 10))
      .reason;
  // CaptureImportService: a validated row the device's reading does not
  // contradict is imported; a contradicted row, or one the validator found
  // contradicts the wording (direction_contradiction), goes to Smart Inbox;
  // any other validation failure falls back to the local parse.
  if (reason == null &&
      !shim.contradicts(t, s['dir'] as String?, s['type'] as String?, snd, s['a'] as num?, s['m'] as String?)) {
    return 'server';
  }
  if (reason == null) return 'inbox';
  return reason == 'direction_contradiction' ? 'inbox:$reason' : 'local';
}

void main() {
  test('parser diff', () => run(Platform.environment['PARSER_DIFF_ARGS']!.split(' ')),
      timeout: const Timeout(Duration(minutes: 30)));
}

void run(List<String> a) {
  final rows = jsonDecode(File(a[0]).readAsStringSync()) as List;
  final srv = <dynamic, Map>{};
  for (final l in File(a[1]).readAsLinesSync()) {
    if (l.isEmpty) continue;
    final m = jsonDecode(l) as Map;
    srv[m['id']] = m;
  }
  final out = StringBuffer();
  for (final e in rows) {
    final m = e as Map;
    final raw = m['text'] as String;
    final s = srv[m['id']]!;
    final r = <String, dynamic>{'id': m['id']};
    // The version's own whole-message status reading.
    try {
      r['nc'] = TransactionStateCues.isNotCompleted(raw);
    } catch (_) {
      r['nc'] = 'THROW';
    }
    r['s'] = s['throw'] != null
        ? {'c': 'THROW', 'p': s['throw']}
        : s['processed'] == true
            ? serverBooked(s, raw)
            : s['ai'] == true
                ? {'c': 'REV', 'p': 'to_ai'}
                : {
                    // A review kind is kept in Smart Inbox; any other
                    // rejection before the AI is silent on the server path.
                    'c': RegExp(r'^(cash_deposit|own_account_transfer|multiple_events|uncertain):')
                            .hasMatch('${s['reason'] ?? ''}')
                        ? 'REV'
                        : 'SIL',
                    'p': 'server_rejected:${s['reason'] ?? ''}'
                  };
    for (final mode in const {'N': null, 'B': 'AlRajhi'}.entries) {
      final d = device(raw, mode.value);
      r['d${mode.key}'] = d;
      if (s['processed'] == true) {
        r['e${mode.key}'] = guarded(() {
          final dec = eff(s, raw, mode.value);
          return dec == 'server'
              ? serverBooked(s, raw)
              : dec == 'local'
                  ? {...d, 'src': 'local'}
                  : {'c': 'REV', 'p': dec};
        });
      } else {
        r['e${mode.key}'] = {...d, 'src': 'local'};
      }
    }
    out.writeln(jsonEncode(r));
  }
  File(a[2]).writeAsStringSync(out.toString());
}
