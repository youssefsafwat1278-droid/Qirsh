#!/usr/bin/env python3
"""Scores one evaluation run against the held-out labels and ACCEPTANCE.md.

usage:
  score.py <messages.json> <server.json> <device.json> --label X --out <prefix>
      writes <prefix>.json (aggregates), <prefix>.md (table) and
      <prefix>.private.json (per-message grades: evaluator only, never shared)
  score.py compare <a.json> <b.json> [...]   prints a side-by-side table

Grading is on the BOOKED outcome: confirmed rows (the only rows any total
reads, drift_transaction_repository._financialAggregateSql), review (pending
rows, Smart Inbox items, suspected duplicates), an ignored row, or nothing.
"""
import collections
import json
import sys

OUT_KINDS = {'payment', 'fee', 'withdrawal', 'transfer_out'}
IN_KINDS = {'income', 'transfer_in', 'refund'}
NOT_MONEY = {'balance_notice', 'bill_due', 'expected_salary', 'marketing', 'otp', 'other_nontxn'}
NOT_DONE = {'declined', 'pending', 'refund_pending'}
PATHS = ['local_only', 'cloud_det', 'cloud_ai_oracle', 'cloud_primary_oracle',
         'cloud_ai_real', 'cloud_primary_real']
REVIEW_BAR = {'local_only': 0.15, 'cloud_det': 0.15, 'cloud_ai_oracle': 0.05,
              'cloud_primary_oracle': 0.05, 'cloud_ai_real': 0.10, 'cloud_primary_real': 0.10}


def expected_effect(events):
    eff = collections.defaultdict(float)
    neutral = False
    for e in events:
        k, a, c = e['kind'], e['amount'], e['currency']
        if k in OUT_KINDS:
            eff[c] -= a
        elif k in IN_KINDS:
            eff[c] += a
        else:
            neutral = True
    return {c: round(v, 3) for c, v in eff.items() if abs(v) > 0.0005}, neutral


def booked_effect(rows):
    eff = collections.defaultdict(float)
    types = []
    neutral = False
    for r in rows:
        amt, cur = r['amount'] or 0, r['currency']
        if not amt and r.get('foreign_amount'):
            amt, cur = r['foreign_amount'], r['foreign_currency']
        t = r['type']
        types.append(t)
        if t in ('payment', 'withdrawal'):
            eff[cur] -= amt
        elif t in ('income', 'refund'):
            eff[cur] += amt
        else:
            neutral = True
    return {c: round(v, 3) for c, v in eff.items() if abs(v) > 0.0005}, neutral, types


def compare_effect(got, want):
    """'' when equal, else the first failure class: WCUR, WDIR, WAMT."""
    if got == want:
        return ''
    if not want and got:
        return 'WDIR'          # neutral (own transfer) booked as money
    if want and not got:
        return 'WDIR'          # a movement booked neutral
    if set(got) != set(want):
        return 'WCUR'
    for c in want:
        if (got[c] > 0) != (want[c] > 0):
            return 'WDIR'
    for c in want:
        if abs(abs(got[c]) - abs(want[c])) > 0.011:
            if abs(abs(got[c]) - 2 * abs(want[c])) < 0.011:
                return 'DUP'
            return 'WAMT'
    return ''


def outcome(r):
    if 'error' in r:
        return 'error'
    if r['confirmed']:
        return 'save'
    if r['pending'] or r['inbox'] or r['suspected']:
        return 'review'
    if r['ignored_rows']:
        return 'excluded'
    return 'none'


def grade(m, r):
    """Returns (grade, extra) for one message on one path."""
    o = outcome(r)
    disp, acc = m['disposition'], set(m['acceptable'])
    if o == 'error':
        return 'ERROR', {}
    extra = {}
    if o == 'save' and len(r.get('redelivered_confirmed', [])) > len(r['confirmed']):
        extra['dup_redelivery'] = True
    if o == 'save':
        got, gneu, types = booked_effect(r['confirmed'])
        options = [m['events']] + m['alt_events']
        if disp == 'save' or 'save' in acc:
            fails = []
            for ev in options:
                if not ev:
                    continue
                want, wneu = expected_effect(ev)
                f = compare_effect(got, want)
                if not f:
                    fails = []
                    want_types = {'refund' if e['kind'] == 'refund' else
                                  'income' if e['kind'] in ('income', 'transfer_in') else None
                                  for e in ev}
                    if 'refund' in want_types and 'refund' not in types and ev is m['events'] and len(options) == 1:
                        extra['wtype'] = True
                    if ('income' in want_types and 'refund' in types and 'refund' not in want_types
                            and len(options) == 1):
                        extra['wtype'] = True
                    break
                fails.append(f)
            if not fails:
                return 'OK', extra
            return fails[0], extra
        if disp == 'review':
            return 'SAVED_AMBIGUOUS', extra
        if m['cls'] in NOT_DONE:
            return 'SAVED_NOT_DONE', extra
        return 'SAVED_NONTXN', extra
    if disp == 'save':
        if 'review' in acc and o == 'review':
            return 'OK_REVIEW', extra
        return ('REVIEW', extra) if o in ('review', 'excluded') else ('LOST', extra)
    if disp == 'review':
        if o in ('review', 'excluded'):
            return 'OK', extra
        return ('OK', extra) if acc & {'exclude', 'ignore'} else ('LOST_AMBIGUOUS', extra)
    # exclude / ignore
    if o in ('review',) and 'review' not in acc:
        return 'OK_NOISE', extra
    return 'OK', extra


def score(messages, server, device, label):
    per = {}
    agg = {'label': label, 'n_messages': len(messages), 'paths': {}}
    by_id = {m['id']: m for m in messages}
    counted = [m for m in messages if not m['policy_dependent']]
    n = collections.Counter(m['disposition'] for m in counted)
    agg['composition'] = {
        'total': len(messages), 'policy_dependent': len(messages) - len(counted),
        'by_disposition': dict(n),
        'by_class': dict(collections.Counter(m['cls'] for m in counted)),
        'by_lang': dict(collections.Counter(m['lang'] for m in messages)),
        'by_region': dict(collections.Counter(m['region'] for m in messages)),
        'no_sender_context': sum(1 for m in messages if not m['sender_context']),
    }
    for path in PATHS:
        rows = {mid: d[path] for mid, d in device.items() if path in d}
        if not rows:
            continue
        g = collections.Counter()
        by_cls = collections.defaultdict(collections.Counter)
        by_tag = collections.defaultdict(collections.Counter)
        policy = collections.Counter()
        inj_wrong = 0
        dups = 0
        wtype = 0
        n_path = collections.Counter()
        for mid, r in rows.items():
            m = by_id[mid]
            gr, extra = grade(m, r)
            per.setdefault(mid, {})[path] = gr + ('+DUPR' if extra.get('dup_redelivery') else '')
            if m['policy_dependent']:
                policy[f"{m['policy_dependent']}|{outcome(r)}|{gr}"] += 1
                continue
            n_path[m['disposition']] += 1
            g[gr] += 1
            by_cls[m['cls']][gr] += 1
            for t in m['tags']:
                by_tag[t][gr] += 1
            if extra.get('dup_redelivery') or gr == 'DUP':
                dups += 1
            if extra.get('wtype'):
                wtype += 1
            if 'injection' in m['tags'] and gr in ('WAMT', 'WCUR', 'WDIR', 'DUP', 'SAVED_NONTXN',
                                                     'SAVED_NOT_DONE', 'SAVED_AMBIGUOUS'):
                inj_wrong += 1
        ns = n_path['save']
        wrong = g['WAMT'] + g['WCUR'] + g['WDIR']
        ignore_cls_saved = sum(c['SAVED_NONTXN'] for k, c in by_cls.items())
        p = {
            'n': dict(n_path),
            'grades': dict(g),
            'A1_nontransactions_saved': ignore_cls_saved,
            'A2_declined_pending_saved': g['SAVED_NOT_DONE'],
            'A3_ambiguous_saved': g['SAVED_AMBIGUOUS'],
            'A4_wrong_amount': g['WAMT'], 'A4_wrong_currency': g['WCUR'],
            'A4_wrong_direction': g['WDIR'],
            'A4_wrong_rate': round(wrong / ns, 4) if ns else None,
            'A4_injection_wrong': inj_wrong,
            'A5_duplicates': dups,
            'A6_lost_silently': g['LOST'] + g['LOST_AMBIGUOUS'],
            'A7_valid_to_review': g['REVIEW'],
            'A7_review_rate': round(g['REVIEW'] / ns, 4) if ns else None,
            'info_nontxn_to_review': g['OK_NOISE'],
            'info_wrong_type_same_direction': wtype,
            'info_errors': g['ERROR'],
            'by_class': {k: dict(v) for k, v in sorted(by_cls.items())},
            'by_tag': {k: dict(v) for k, v in sorted(by_tag.items())},
            'policy_dependent': dict(policy),
        }
        checks = {
            'A1': p['A1_nontransactions_saved'] == 0,
            'A2': p['A2_declined_pending_saved'] == 0,
            'A3': p['A3_ambiguous_saved'] == 0,
            'A4': (p['A4_wrong_rate'] or 0) <= 0.01 and inj_wrong == 0,
            'A5': dups == 0,
            'A6': p['A6_lost_silently'] == 0,
            'A7': (p['A7_review_rate'] or 0) <= REVIEW_BAR[path],
        }
        if path == 'cloud_primary_oracle':
            p['A8b_correct_ai_not_saved'] = g['REVIEW'] + g['LOST']
            p['A8b_rate'] = round(p['A8b_correct_ai_not_saved'] / ns, 4) if ns else None
            checks['A8b'] = (p['A8b_rate'] or 0) <= 0.05
        p['checks'] = checks
        p['pass'] = all(checks.values())
        agg['paths'][path] = p

    # Validators on the ground-truth candidate (completed, non-policy messages).
    for side, get in (('server_validator', lambda mid: server.get(mid, {}).get('validator')),
                      ('device_validator', lambda mid: device.get(mid, {}).get('device_validator'))):
        acc = rej = 0
        reasons = collections.Counter()
        for m in counted:
            v = get(m['id'])
            if not v:
                continue
            if v['accepted']:
                acc += 1
            else:
                rej += 1
                reasons[v['reason']] += 1
        tot = acc + rej
        agg[side] = {'candidates': tot, 'rejected': rej,
                     'rate': round(rej / tot, 4) if tot else None,
                     'reasons': dict(reasons), 'A8a_pass': (rej / tot if tot else 0) <= 0.05}

    # Server reading alone (what a push notification would claim).
    srv = {}
    for mode in ('det', 'hybrid_oracle', 'primary_oracle', 'hybrid_real', 'primary_real'):
        c = collections.Counter()
        for m in counted:
            s = server.get(m['id'], {}).get(mode)
            if not s:
                continue
            processed = s['state'] == 'processed'
            c[f"{m['disposition']}:{'processed' if processed else s['state']}"] += 1
        if c:
            srv[mode] = dict(c)
    agg['server_reading'] = srv
    return agg, per


def md(agg):
    lines = [f"### {agg['label']}", '',
             '| Path | A1 non-txn saved | A2 declined/pending saved | A3 ambiguous saved | '
             'A4 wrong amt / cur / dir (rate) | A4 injection | A5 dup | A6 lost | '
             'A7 to review (rate) | noise→review | PASS |',
             '|---|---|---|---|---|---|---|---|---|---|---|']
    for path, p in agg['paths'].items():
        lines.append(
            f"| {path} | {p['A1_nontransactions_saved']} | {p['A2_declined_pending_saved']} | "
            f"{p['A3_ambiguous_saved']} | {p['A4_wrong_amount']} / {p['A4_wrong_currency']} / "
            f"{p['A4_wrong_direction']} ({pct(p['A4_wrong_rate'])}) | {p['A4_injection_wrong']} | "
            f"{p['A5_duplicates']} | {p['A6_lost_silently']} | {p['A7_valid_to_review']} "
            f"({pct(p['A7_review_rate'])}) | {p['info_nontxn_to_review']} | "
            f"{'PASS' if p['pass'] else 'FAIL: ' + ','.join(k for k, v in p['checks'].items() if not v)} |")
    for side in ('server_validator', 'device_validator'):
        v = agg[side]
        lines.append(f"\n{side}: rejects {v['rejected']} of {v['candidates']} correct candidates "
                     f"({pct(v['rate'])}); reasons {v['reasons']}")
    return '\n'.join(lines) + '\n'


def pct(x):
    return '-' if x is None else f'{100 * x:.1f}%'


def main():
    if sys.argv[1] == 'compare':
        aggs = [json.load(open(p)) for p in sys.argv[2:]]
        for a in aggs:
            print(md(a))
        return
    msgs = json.load(open(sys.argv[1]))['messages']
    server = json.load(open(sys.argv[2]))['server']
    device = json.load(open(sys.argv[3]))['device']
    label = sys.argv[sys.argv.index('--label') + 1]
    prefix = sys.argv[sys.argv.index('--out') + 1]
    real = json.load(open(sys.argv[2])).get('real')
    agg, per = score(msgs, server, device, label)
    agg['real_model'] = real
    json.dump(agg, open(prefix + '.json', 'w'), indent=1, ensure_ascii=False)
    json.dump(per, open(prefix + '.private.json', 'w'), indent=0)
    open(prefix + '.md', 'w').write(md(agg))
    print(md(agg))


if __name__ == '__main__':
    main()
