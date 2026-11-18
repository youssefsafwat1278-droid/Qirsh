#!/usr/bin/env python3
"""Three-layer report of one real-model run (see run_real.sh).

usage: report.py <outDir> --label X [--price-in USD_per_1M --price-out USD_per_1M]

Reads <outDir>/messages.json, server_real.json, device.json,
client_sanitized.json and requests/*.json; writes <outDir>/report.json,
report.md and per_message.json.

Layers, each graded against the pre-recorded label:
  1. Gemini's interpretation: the model's FIRST structured answer (before any
     repair turn the validator asked for); the last answer is kept too.
  2. The decision of the code: server (pre-filter, validator on each answer,
     meaning gate, stored state) and device (import gate).
  3. What Qirsh saved: rows, their status, and whether they enter totals.
     Graded by ../score.py `grade` (the held-out evaluation's rules, unchanged).

These grading rules were written before the first real-model request.
"""
import collections
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import score  # noqa: E402

DIR = {'payment': 'debit', 'fee': 'debit', 'withdrawal': 'debit', 'transfer_out': 'debit',
       'transfer_in': 'credit', 'income': 'credit', 'refund': 'credit', 'own_transfer': 'debit'}
WRONG = {'WAMT', 'WCUR', 'WDIR', 'DUP', 'SAVED_NOT_DONE', 'SAVED_NONTXN', 'SAVED_AMBIGUOUS'}
LOSS = {'LOST', 'LOST_AMBIGUOUS'}
REVIEW_TYPES = {'multiple_transactions', 'own_account_transfer', 'ambiguous'}
AR_DIGITS = str.maketrans('٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789')


def bucket(grade, extra):
    if grade in WRONG or extra.get('dup_redelivery'):
        return 'wrong_entry'
    if grade in LOSS:
        return 'silent_loss'
    if grade == 'REVIEW':
        return 'unnecessary_review'
    if grade in ('WAITING', 'ERROR', 'NOT_RUN'):
        return grade.lower()
    return 'ok'


def num(a):
    for v in (a.get('amount_text'), a.get('amount')):
        try:
            return float(str(v).replace(',', ''))
        except (TypeError, ValueError):
            continue
    return None


def direction_of(a):
    d = a.get('direction')
    if d in ('credit', 'debit'):
        return d
    return 'credit' if a.get('type') in ('income', 'refund') else 'debit'


def gemini_grade(m, attempt):
    """Grade of one model answer against the label. Returns (grade, note)."""
    code = attempt.get('code') or {}
    a = code.get('answer')
    if a is None:
        return 'G_INVALID', 'no JSON object'
    txn = code.get('decision') != 'terminal_not_transaction' and a.get('is_transaction') is True
    mtype = a.get('message_type')
    disp, acc = m['disposition'], set(m['acceptable'])
    if disp != 'save':
        return ('G_FALSE_TRANSACTION', 'answered a completed transaction') if txn else ('G_RIGHT', mtype or 'not a transaction')
    if not txn:
        if 'review' in acc and mtype in REVIEW_TYPES:
            return 'G_RIGHT', f'review reading ({mtype})'
        return 'G_MISSED', f'said {mtype or "not a transaction"}/{a.get("status") or "-"}'
    events = m['events']
    if m['cls'] == 'multi_event' or len(events) > 1:
        return 'G_PARTIAL', 'one answer for a message with several movements'
    e = events[0]
    amt, cur, d = num(a), (a.get('currency') or '').upper(), direction_of(a)
    if e['kind'] == 'own_transfer':
        if a.get('type') == 'transfer' and amt is not None and abs(amt - e['amount']) < 0.011:
            return 'G_RIGHT', 'transfer (neutral in totals)'
        return 'G_WRONG_DIRECTION', 'own-account move answered as spending or income'
    for ev in [events] + m['alt_events']:
        if len(ev) == 1 and amt is not None and abs(amt - ev[0]['amount']) < 0.011 \
                and cur == ev[0]['currency'] and d == DIR[ev[0]['kind']]:
            return 'G_RIGHT', ''
    if amt is None or abs(amt - e['amount']) >= 0.011:
        return 'G_WRONG_AMOUNT', f'{a.get("amount_text")} vs {e["amount_text"]}'
    if cur != e['currency']:
        return 'G_WRONG_CURRENCY', f'{cur} vs {e["currency"]}'
    return 'G_WRONG_DIRECTION', f'{d} vs {DIR[e["kind"]]}'


def interpretation(attempt):
    a = (attempt.get('code') or {}).get('answer') or {}
    keys = ['is_transaction', 'message_type', 'status', 'amount_text', 'amount', 'currency', 'direction', 'type',
            'merchant', 'category', 'original_amount_text', 'original_currency', 'amount_evidence',
            'status_evidence', 'direction_evidence', 'currency_evidence', 'merchant_evidence',
            'missing_information', 'contradictions']
    return {k: a[k] for k in keys if k in a}


def server_decision(s):
    sv, attempts = s['server'], s['attempts']
    ok = [a for a in attempts if a.get('http_status') == 200]
    if sv['state'] == 'processed':
        return 'processed', 'validators and meaning gate accepted the answer'
    if sv['state'] == 'retryable':
        return 'retryable', sv['failure_reason'] or 'provider not reached'
    if not attempts:
        why = sv['review_reason'] or ('deterministic ignore filter' if sv['meaning']['disposition'] == 'record'
                                      else sv['meaning']['reason'])
        return 'not_sent', f'never sent to the model ({why}; server meaning {sv["meaning"]["kind"]})'
    if sv['parser_source'] == 'ai_ignored':
        v = (ok[-1].get('code') or {}).get('verdict', {}) if ok else {}
        return 'model_not_transaction', f'model verdict {v.get("message_type") or "-"}/{v.get("status") or "-"}: kept for review'
    if sv['parser_source'] == 'ai':
        return 'meaning_gate', f'answer accepted by the validator, then refused by the meaning gate ({sv["review_reason"]})'
    reasons = [(a.get('code') or {}).get('reason') or f'HTTP {a.get("http_status")}' for a in attempts]
    return 'validator', 'validator rejected every answer: ' + ' → '.join(str(r) for r in reasons)


def device_decision(dev, real):
    g = dev['device_gate']
    if real['confirmed'] or real['rows']:
        return 'imported', 'server row imported'
    if not g['server_processed']:
        if not real['inbox'] and not real['pending']:
            return 'dropped', 'not saved, not in review' + (' (device ignore filter)' if dev['local_ignored'] else '')
        return 'review', 'server row not processed: full message kept in Smart Inbox'
    if g['hold_reason']:
        return 'held', f'device meaning hold: {g["hold_reason"]}'
    if g['validation_reason']:
        return 'held', f'device validation: {g["validation_reason"]}'
    if g['local_contradicts']:
        return 'held', 'device reading contradicts the server row'
    return 'review', 'not imported'


def saved(r):
    """What was saved, in words and as data."""
    if 'error' in r:
        return {'summary': 'error: ' + r['error'], 'in_totals': False, 'rows': []}
    rows = r['rows']
    conf = [x for x in rows if x['status'] == 'confirmed']
    in_totals = [x for x in conf if x['type'] in ('payment', 'withdrawal', 'refund', 'income')]
    if conf:
        s = 'confirmed: ' + '; '.join(f'{x["type"]} {x["amount"]} {x["currency"]} {x["direction"]}' for x in conf)
    elif r['pending'] or r['inbox'] or r['suspected']:
        reasons = [str(x['reason']) for x in r['inbox_rows'] if x.get('reason')]
        s = 'review (Smart Inbox' + (': ' + ', '.join(reasons) if reasons else '') + ')'
    elif r['ignored_rows']:
        s = 'excluded row'
    else:
        s = 'not saved'
    return {'summary': s, 'in_totals': bool(in_totals), 'rows': rows,
            'inbox_reasons': [x.get('reason') for x in r['inbox_rows']]}


def token_kind(t):
    if '@' in t:
        return 'email address'
    if re.fullmatch(r'[A-Z]{2}[0-9]{10,32}', t):
        return 'IBAN'
    if re.fullmatch(r'[0-9]{6}', t):
        return 'one-time code'
    if re.fullmatch(r'0[0-9]{9,10}|\+[0-9]{8,15}', t):
        return 'phone number'
    if re.fullmatch(r'[0-9]{8,}', t):
        return 'account number'
    return 'person name'


def main():
    out = sys.argv[1]
    args = sys.argv[2:]
    opt = {args[i]: args[i + 1] for i in range(0, len(args) - 1, 2)}
    label = opt.get('--label', os.path.basename(out))
    msgs = json.load(open(f'{out}/messages.json', encoding='utf-8'))['messages']
    srv = json.load(open(f'{out}/server_real.json', encoding='utf-8'))
    dev = json.load(open(f'{out}/device.json', encoding='utf-8'))['device']
    client = json.load(open(f'{out}/client_sanitized.json', encoding='utf-8'))
    meta, server = srv['meta'], srv['server']

    per = {}
    for m in msgs:
        mid = m['id']
        if mid not in server or mid not in dev:
            continue
        s, d = server[mid], dev[mid]
        ok = [a for a in s['attempts'] if a.get('http_status') == 200]
        g_first = gemini_grade(m, ok[0]) if ok else (('NOT_ASKED', 'never sent to the model') if not s['attempts']
                                                     else ('NO_ANSWER', 'no HTTP 200'))
        g_last = gemini_grade(m, ok[-1]) if ok else g_first
        lg, lextra = score.grade(m, d['local_only'])
        real = d['cloud_primary_real']
        if 'error' not in real and s['server']['state'] == 'retryable' and score.outcome(real) == 'none':
            rg, rextra = 'WAITING', {}
        else:
            rg, rextra = score.grade(m, real)
        sd, dd = server_decision(s), device_decision(d, real) if 'error' not in real else ('error', real['error'])
        per[mid] = {
            'id': mid, 'family': m['family'], 'cls': m['cls'], 'lang': m['lang'], 'policy': m['policy_dependent'],
            'label': {'disposition': m['disposition'], 'acceptable': m['acceptable'], 'events': m['events']},
            'text': m['text'],
            'local': {'meaning': d['local_meaning'], 'ignored': d['local_ignored'],
                      'saved': saved(d['local_only']), 'grade': lg, 'bucket': bucket(lg, lextra)},
            'gemini': {'asked': bool(s['attempts']), 'requests': len(s['attempts']),
                       'first': interpretation(ok[0]) if ok else None, 'first_grade': g_first[0], 'first_note': g_first[1],
                       'last': interpretation(ok[-1]) if len(ok) > 1 else None, 'last_grade': g_last[0],
                       'attempt_decisions': [
                           {'http': a.get('http_status'), 'decision': (a.get('code') or {}).get('decision'),
                            'reason': (a.get('code') or {}).get('reason'),
                            'reason_in_repair_prompt': a.get('code_reason_in_repair_prompt'),
                            'latency_ms': a.get('latency_ms')} for a in s['attempts']]},
            'server': {'decision': sd[0], 'why': sd[1], 'state': s['server']['state'],
                       'parser_source': s['server']['parser_source'], 'review_reason': s['server']['review_reason'],
                       'meaning': s['server']['meaning'], 'money': s['server']['money']},
            'device': {'decision': dd[0], 'why': dd[1], 'gate': d['device_gate']},
            'real': {'saved': saved(real), 'grade': rg, 'bucket': bucket(rg, rextra)},
        }

    counted = [p for p in per.values() if not p['policy']]
    n_save = sum(1 for p in counted if p['label']['disposition'] == 'save')

    def tally(path):
        c = collections.Counter(p[path]['bucket'] for p in counted)
        g = collections.Counter(p[path]['grade'] for p in counted)
        return {'buckets': dict(c), 'grades': dict(g),
                'wrong_entries': c['wrong_entry'], 'silent_losses': c['silent_loss'],
                'unnecessary_reviews': c['unnecessary_review'],
                'saved_correctly': g['OK'] if path else 0,
                'nontransactions_in_review': g['OK_NOISE']}

    # Cross-layer reading of the real path.
    cross = collections.Counter()
    for p in counted:
        gg, b, disp = p['gemini']['first_grade'], p['real']['bucket'], p['label']['disposition']
        strict_save = disp == 'save' and not p['label']['acceptable']
        if gg == 'NOT_ASKED':
            key = 'not_asked/' + ('ok' if b == 'ok' else b)
        elif gg == 'G_RIGHT':
            if b == 'ok':
                key = 'gemini_right/outcome_ok'
            elif b in ('unnecessary_review', 'silent_loss', 'waiting'):
                key = 'gemini_right/overruled_to_' + b
            else:
                key = 'gemini_right/' + b
        else:
            if b == 'wrong_entry':
                key = 'gemini_wrong/let_through_wrong_entry'
            elif b == 'ok' and strict_save:
                key = 'gemini_wrong/corrected_saved_ok'
            elif b == 'ok':
                key = 'gemini_wrong/caught_no_wrong_entry'
            else:
                key = 'gemini_wrong/caught_as_' + b
        p['cross'] = key
        cross[key] += 1

    fam = collections.defaultdict(lambda: collections.Counter())
    for p in counted:
        f = fam[p['family']]
        f['n'] += 1
        f['local_' + p['local']['bucket']] += 1
        f['real_' + p['real']['bucket']] += 1
        g = p['gemini']['first_grade']
        f['gemini_' + ('right' if g == 'G_RIGHT' else 'not_asked' if g == 'NOT_ASKED' else 'wrong')] += 1

    # Privacy: labelled third-party tokens in what left the device and in what reached the model.
    priv = {'messages_with_tokens': 0, 'tokens': 0, 'in_upload': [], 'in_model_request': [], 'generic_hits': []}
    bodies = collections.defaultdict(list)
    for path in glob.glob(f'{out}/requests/*.json'):
        mid = os.path.basename(path).split('_')[0]
        try:
            req = json.load(open(path, encoding='utf-8'))
            texts = [('systemInstruction.parts[0].text', (req.get('systemInstruction') or {}).get('parts', [{}])[0].get('text', ''))]
            texts += [(f'contents[{i}].parts[{j}].text', part.get('text', ''))
                      for i, c in enumerate(req.get('contents', [])) for j, part in enumerate(c.get('parts', []))]
        except ValueError:
            texts = [('raw body', open(path, encoding='utf-8').read())]
        bodies[mid] += texts
    by_id = {m['id']: m for m in msgs}
    for mid, m in by_id.items():
        if not m['privacy_tokens'] or mid not in per:
            continue
        priv['messages_with_tokens'] += 1
        up = client[mid].translate(AR_DIGITS).lower()
        for t in m['privacy_tokens']:
            priv['tokens'] += 1
            tt = t.translate(AR_DIGITS).lower()
            if tt in up:
                priv['in_upload'].append({'id': mid, 'kind': token_kind(t), 'token': t})
            for field, text in bodies.get(mid, []):
                if tt in text.translate(AR_DIGITS).lower():
                    priv['in_model_request'].append({'id': mid, 'kind': token_kind(t), 'token': t, 'field': field})
                    break
    generic = re.compile(r'[0-9]{9,}|[A-Z]{2}[0-9]{2}[0-9A-Z]{10,}|[\w.+-]+@[\w-]+\.[\w.]+')
    for mid, texts in bodies.items():
        for field, text in texts:
            if not field.startswith('contents'):
                continue
            sms = text[text.rfind('\nSMS:\n') + 6:].translate(AR_DIGITS)
            sms = sms.split('\nReview your extraction again.')[0]
            for hit in generic.findall(sms):
                priv['generic_hits'].append({'id': mid, 'field': field, 'shape': re.sub(r'[0-9]', '9', re.sub(r'[A-Za-z]', 'a', hit))})
    priv['request_bodies_checked'] = sum(len(v) > 0 for v in bodies.values())
    priv['request_files'] = len(glob.glob(f'{out}/requests/*.json'))
    priv['store_false_everywhere'] = all(
        json.load(open(p, encoding='utf-8')).get('store') is False for p in glob.glob(f'{out}/requests/*.json'))

    tok = meta['tokens']
    cost = None
    if '--price-in' in opt and '--price-out' in opt:
        pin, pout = float(opt['--price-in']), float(opt['--price-out'])
        cost = {'usd_per_1m_input': pin, 'usd_per_1m_output': pout,
                'input_usd': tok['prompt'] * pin / 1e6, 'output_usd': (tok['output'] + tok['thoughts']) * pout / 1e6}
        cost['total_usd'] = cost['input_usd'] + cost['output_usd']
        cost['per_message_usd'] = cost['total_usd'] / max(1, meta['messages_run'])

    gem = collections.Counter(p['gemini']['first_grade'] for p in counted)
    repaired = [p['id'] for p in counted if p['gemini']['requests'] > 1]
    agg = {
        'label': label, 'meta': meta, 'n': len(per), 'n_counted': len(counted), 'n_policy': len(per) - len(counted),
        'n_save_counted': n_save,
        'local_only': tally('local'), 'real': tally('real'),
        'gemini_first_answer': dict(gem), 'gemini_last_answer': dict(collections.Counter(p['gemini']['last_grade'] for p in counted)),
        'messages_with_more_than_one_request': repaired,
        'cross': dict(cross), 'by_family': {k: dict(v) for k, v in sorted(fam.items())},
        'privacy': priv, 'cost': cost,
        'policy_rows': [{'id': p['id'], 'policy': p['policy'], 'local': p['local']['saved']['summary'],
                         'real': p['real']['saved']['summary'], 'gemini': p['gemini']['first_grade']}
                        for p in per.values() if p['policy']],
    }
    json.dump(agg, open(f'{out}/report.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    json.dump(per, open(f'{out}/per_message.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

    L = []
    w = L.append
    w(f'## Run `{label}`: {len(per)} messages ({len(counted)} counted, {len(per) - len(counted)} policy-dependent), '
      f'{n_save} completed among the counted\n')
    w('| | Local only | Real model path |\n|---|---|---|')
    lo, re_ = agg['local_only'], agg['real']
    for name, k in [('Wrong financial entries (in totals)', 'wrong_entries'), ('Silent losses', 'silent_losses'),
                    ('Unnecessary reviews (correct completed → review)', 'unnecessary_reviews'),
                    ('Non-transactions kept in review (information)', 'nontransactions_in_review')]:
        w(f'| {name} | {lo[k]} | {re_[k]} |')
    w(f'| Grades | {json.dumps(lo["grades"], sort_keys=True)} | {json.dumps(re_["grades"], sort_keys=True)} |\n')
    w('### Gemini\'s first answer vs the label (counted messages)\n')
    w('| Grade | Count |\n|---|---|')
    for k, v in sorted(gem.items()):
        w(f'| {k} | {v} |')
    w('\n### Gemini vs validator vs outcome (real path)\n')
    w('| Case | Count |\n|---|---|')
    for k, v in sorted(cross.items()):
        w(f'| {k} | {v} |')
    w('\n### By class (counted messages)\n')
    w('| Class | n | Local: ok / wrong / lost / unnecessary review | Real: ok / wrong / lost / unnecessary review / waiting | Gemini: right / wrong / not asked |\n|---|---|---|---|---|')
    for k, f in sorted(fam.items()):
        w(f'| {k} | {f["n"]} | {f["local_ok"]} / {f["local_wrong_entry"]} / {f["local_silent_loss"]} / {f["local_unnecessary_review"]} '
          f'| {f["real_ok"]} / {f["real_wrong_entry"]} / {f["real_silent_loss"]} / {f["real_unnecessary_review"]} / {f["real_waiting"]} '
          f'| {f["gemini_right"]} / {f["gemini_wrong"]} / {f["gemini_not_asked"]} |')
    w('\n### Measurements\n')
    w(f'- Model called: `{", ".join(meta["models_called"]) or "-"}`; `modelVersion` returned: `{", ".join(meta["model_versions_returned"]) or "-"}`')
    w(f'- Requests this run: {meta["requests_this_run"]} (HTTP statuses {json.dumps(meta["http_statuses"])}); '
      f'counter {meta["counter_before"]} → {meta["counter_after"]} of {meta["cap"]}; refused by the cap: {meta["refused_by_wrapper"]}; '
      f'messages not started because of the cap: {len(meta["skipped_by_cap"])}')
    w(f'- Messages sent to the model: {meta["messages_sent_to_model"]} of {meta["messages_run"]}; with more than one request: {len(repaired)}')
    w(f'- Latency per request (ms): p50 {meta["latency_ms"]["p50"]}, p95 {meta["latency_ms"]["p95"]}, max {meta["latency_ms"]["max"]}')
    w(f'- Tokens: input {tok["prompt"]}, output {tok["output"]}, thinking {tok["thoughts"]}, cached {tok["cached"]}, total {tok["total"]}')
    if cost:
        w(f'- Cost: ${cost["total_usd"]:.4f} (input ${cost["input_usd"]:.4f} at ${cost["usd_per_1m_input"]}/1M, '
          f'output+thinking ${cost["output_usd"]:.4f} at ${cost["usd_per_1m_output"]}/1M); ${cost["per_message_usd"]:.5f} per message')
    w('\n### Privacy\n')
    w(f'- Labelled third-party tokens: {priv["tokens"]} in {priv["messages_with_tokens"]} messages; request files: {priv["request_files"]}; `store:false` on every request: {priv["store_false_everywhere"]}')
    w(f'- Still present in the upload from the device: {len(priv["in_upload"])}; present in a model request: {len(priv["in_model_request"])}')
    for h in priv['in_model_request']:
        w(f'  - {h["id"]}: {h["kind"]} in `{h["field"]}`')
    w(f'- Generic scan of the SMS part of every request (digit runs ≥ 9, IBAN shapes, e-mail shapes): {len(priv["generic_hits"])} hits')
    for h in priv['generic_hits']:
        w(f'  - {h["id"]}: `{h["shape"]}` in `{h["field"]}`')
    w('\n### Every message that fails on a path, or where Gemini\'s first answer is wrong\n')
    for p in per.values():
        fails = p['local']['bucket'] != 'ok' or p['real']['bucket'] != 'ok' or \
            p['gemini']['first_grade'] not in ('G_RIGHT', 'NOT_ASKED')
        if not fails:
            continue
        ev = '; '.join(f'{e["kind"]} {e["amount_text"]} {e["currency"]}' for e in p['label']['events']) or '-'
        w(f'**{p["id"]}** ({p["family"]}, {p["lang"]}{", policy-dependent: " + p["policy"] if p["policy"] else ""}) — '
          f'label: {p["label"]["disposition"]}{" or " + "/".join(p["label"]["acceptable"]) if p["label"]["acceptable"] else ""} [{ev}]')
        w('> ' + p['text'].replace('\n', ' ⏎ '))
        w(f'- Local only: device meaning `{p["local"]["meaning"]["kind"]}/{p["local"]["meaning"]["reason"]}` → {p["local"]["saved"]["summary"]} → **{p["local"]["grade"]}**')
        g = p['gemini']
        if g['first'] is None:
            w(f'- Gemini: {g["first_note"]}')
        else:
            f = g['first']
            brief = {k: f[k] for k in ('message_type', 'status', 'is_transaction', 'amount_text', 'currency', 'direction', 'type', 'merchant') if k in f}
            w(f'- Gemini (first answer, {g["requests"]} request(s)): `{json.dumps(brief, ensure_ascii=False)}` → **{g["first_grade"]}** {g["first_note"]}')
            if g['last'] is not None:
                f = g['last']
                brief = {k: f[k] for k in ('message_type', 'status', 'is_transaction', 'amount_text', 'currency', 'direction', 'type') if k in f}
                w(f'  - last answer: `{json.dumps(brief, ensure_ascii=False)}` → {g["last_grade"]}; per request: '
                  + ', '.join(f'{a["decision"] or "HTTP " + str(a["http"])}{":" + a["reason"] if a["reason"] else ""}' for a in g['attempt_decisions']))
        w(f'- Validator/gate: server `{p["server"]["decision"]}` — {p["server"]["why"]}; device `{p["device"]["decision"]}` — {p["device"]["why"]}')
        w(f'- Saved (real path): {p["real"]["saved"]["summary"]}; in totals: {p["real"]["saved"]["in_totals"]} → **{p["real"]["grade"]}** ({p["cross"] if not p["policy"] else "policy-dependent, not counted"})\n')
    open(f'{out}/report.md', 'w', encoding='utf-8').write('\n'.join(L) + '\n')
    print(json.dumps({k: agg[k] for k in ('label', 'n', 'n_counted', 'local_only', 'real', 'gemini_first_answer', 'cross')},
                     ensure_ascii=False))


if __name__ == '__main__':
    main()
