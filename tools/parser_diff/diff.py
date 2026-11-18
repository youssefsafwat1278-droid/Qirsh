#!/usr/bin/env python3
"""Parser differential harness: case assembly and the base/work comparison.

  diff.py cases <cases dir> <declined_cases.json> <out cases.json>
  diff.py diff <cases.json> <base out.jsonl> <work out.jsonl>
  diff.py freeze <cases.json> <base out.jsonl> <fixture.json>

Labels (`truth.kind`): d = completed debit, c = completed credit,
t = between own accounts (neutral), k = completed (any direction),
n = not a movement (anything but a booking is right), r = must be a review
row (a booking or silence is wrong). `amt`/`cur` (and `alt` = an accepted
[amount, currency]) check the booked value.
"""
import collections, glob, json, os, sys

SIDES = ['dB', 'dN', 's', 'eB', 'eN']
WRONG = {'WDIR', 'WAMT', 'WCUR', 'WREC', 'WOWN', 'WNEU', 'THROW'}
TEXP = {'completed_payment': 'd', 'completed_withdrawal': 'd', 'completed_income': 'c',
        'completed_credit': 'c', 'completed_transfer_in': 'c', 'completed_transfer_own': 't',
        'not_completed': 'n', 'ignored': 'n'}
CASH = ('atm', 'صراف', 'cash deposit', 'إيداع نقدي', 'ايداع نقدي', 'cash deposited')


def build(cases_dir, table, out):
    rows = []
    for f in sorted(glob.glob(os.path.join(cases_dir, '*.json'))):
        name = os.path.basename(f)[:-5]
        for e in json.load(open(f, encoding='utf-8')):
            rows.append({**e, 'id': f'{name}/{e["id"]}', 'set': name})
    for i, e in enumerate(json.load(open(table, encoding='utf-8'))['cases']):
        t = {'kind': TEXP[e['expect']]}
        if 'amount' in e: t['amt'] = e['amount']
        if 'currency' in e: t['cur'] = e['currency']
        if 'foreign' in e: t['alt'] = [e['foreign']['amount'], e['foreign']['currency']]
        rows.append({'id': f'table/T{i:04d}', 'set': 'table', 'text': e['text'], 'truth': t})
    json.dump(rows, open(out, 'w', encoding='utf-8'), ensure_ascii=False)
    print(f'{len(rows)} cases ({sum(1 for r in rows if "truth" in r)} labelled)')


def outcome(o):
    """The outcome class a path reached, with direction and amount."""
    c, p = o['c'], str(o.get('p', ''))
    if c in ('IN', 'OUT', 'NEU'):
        a = o.get('a')
        return f'record {c} {a:g} {o.get("cur")}' if isinstance(a, (int, float)) else f'record {c} ? {o.get("cur")}'
    if c == 'THROW':
        return 'THROW ' + p
    if 'not_completed' in p or 'notCompleted' in p:
        return 'not-completed'
    if 'no_movement' in p or 'noMovement' in p:
        return 'no-movement'
    if c == 'SIL':
        return 'ignored'
    if p == 'drop':
        return 'dropped'
    return 'review'


def grade(o, t, text=''):
    c = o['c']
    if c == 'THROW':
        return 'THROW'
    if t is None:
        return None
    k = t['kind']
    if k == 'n':
        return 'WREC' if c in ('OUT', 'IN', 'NEU') else 'OK'
    if k == 'r':
        return 'WREC' if c in ('OUT', 'IN', 'NEU') else 'SILENT' if c == 'SIL' else 'OK'
    if c == 'SIL':
        return 'SILENT'
    if c == 'REV':
        return 'REVIEW'
    if k == 't':
        return 'OK' if c == 'NEU' else 'WOWN'
    if c == 'NEU':
        return 'OK' if k == 'c' and any(w in text.lower() for w in CASH) else 'WNEU'
    if k in ('d', 'c') and (k == 'd') != (c == 'OUT'):
        return 'WDIR'
    amt = t.get('amt')
    if amt is not None:
        near = lambda v, w: v is not None and w is not None and abs(float(v) - float(w)) < 0.005
        a, fa, alt = o.get('a'), o.get('fa'), t.get('alt')
        okA, okF, okAlt = near(a, amt), near(fa, amt), alt is not None and near(a, alt[0])
        if not (okA or okF or okAlt):
            return 'WAMT'
        cur = t.get('cur')
        if cur and not ((okA and o.get('cur') == cur) or (okF and o.get('fcur') == cur)
                        or (okAlt and o.get('cur') == alt[1])):
            return 'WCUR'
    return 'OK'


def compare(cases, base, work):
    rows = json.load(open(cases, encoding='utf-8'))
    load = lambda f: {j['id']: j for j in map(json.loads, filter(None, open(f, encoding='utf-8').read().split('\n')))}
    B, W = load(base), load(work)
    seen, uniq = set(), []
    for r in rows:
        if r['text'] in seen: continue
        seen.add(r['text']); uniq.append(r)
    print(f'{len(uniq)} distinct messages ({sum(1 for r in uniq if "truth" in r)} labelled)\n')
    moved = collections.defaultdict(list)
    bad = 0
    for side in SIDES:
        gb, gw = collections.Counter(), collections.Counter()
        for r in uniq:
            t = r.get('truth')
            ob, ow = B[r['id']][side], W[r['id']][side]
            a, b = grade(ob, t, r['text']), grade(ow, t, r['text'])
            gb[a] += 1; gw[b] += 1
            if outcome(ob) == outcome(ow) and a == b: continue
            if b == 'THROW' or (a == 'OK' and b in WRONG | {'SILENT'}):
                cls = 'REGRESSION'
            elif a in WRONG | {'SILENT'} and b == 'OK': cls = 'fixed'
            elif a in WRONG | {'SILENT'} and b == 'REVIEW': cls = 'wrong/silent -> review'
            elif a == 'OK' and b == 'REVIEW': cls = 'right -> review'
            elif a == 'REVIEW' and b == 'OK': cls = 'review -> right'
            elif a in WRONG and b in WRONG: cls = 'wrong -> other wrong'
            elif t is None: cls = 'unlabelled move'
            else: cls = 'outcome moved, same grade'
            if cls == 'REGRESSION': bad += 1
            moved[cls].append((side, r, outcome(ob), outcome(ow), a, b))
        ws = lambda g: sum(g[k] for k in WRONG)
        print(f'{side}: wrong {ws(gb)}->{ws(gw)} silent {gb["SILENT"]}->{gw["SILENT"]} '
              f'review {gb["REVIEW"]}->{gw["REVIEW"]} right {gb["OK"]}->{gw["OK"]} throw {gb["THROW"]}->{gw["THROW"]}')
    order = ['REGRESSION', 'wrong -> other wrong', 'right -> review', 'unlabelled move', 'outcome moved, same grade',
             'fixed', 'wrong/silent -> review', 'review -> right']
    for cls in order:
        items = moved.get(cls, [])
        print(f'\n== {cls}: {len(items)} path-moves, {len({i[1]["id"] for i in items})} messages')
        by = collections.defaultdict(list)
        for side, r, x, y, a, b in items:
            by[r['id']].append(f'{side}: {x} -> {y}' + (f' [{a}->{b}]' if r.get('truth') else ''))
        for i, (rid, ch) in enumerate(by.items()):
            r = next(x for x in uniq if x['id'] == rid)
            print(f'- {rid} truth={r.get("truth")} {r["text"][:160]!r}')
            for c in ch: print('    ' + c)
    # The invariant: a message the base read as not completed is never
    # recorded as a completed movement on any path.
    nc_recorded = []
    for r in uniq:
        if B[r['id']].get('nc') is not True: continue
        hits = [s for s in SIDES if W[r['id']][s]['c'] in ('IN', 'OUT', 'NEU')]
        if hits: nc_recorded.append((r, hits))
    print(f'\n== base not-completed, now recorded: {len(nc_recorded)}')
    for r, hits in nc_recorded:
        print(f'- {r["id"]} {hits} {r["text"][:160]!r}')
    bad += len(nc_recorded)
    print(f'\nREGRESSIONS (right at base -> wrong/silent, a throw, or base not-completed now recorded): {bad}')
    return bad


def freeze(cases, base, out):
    """Writes the texts the base read as not completed (the invariant fixture)."""
    rows = json.load(open(cases, encoding='utf-8'))
    B = {j['id']: j for j in map(json.loads, filter(None, open(base, encoding='utf-8').read().split('\n')))}
    texts = sorted({r['text'] for r in rows if B[r['id']].get('nc') is True})
    json.dump({'_readme': 'Texts that the pre-round parser (5dae2e2d) read as not completed '
               '(TransactionStateCues.isNotCompleted), over the parser_diff case files and the shared case '
               'table. Generated by tools/parser_diff (diff.py freeze). Invariant: none is ever recorded as a '
               'completed movement (a footer rule may only make it a review row).',
               'texts': texts}, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
    print(f'{len(texts)} texts')


if __name__ == '__main__':
    if sys.argv[1] == 'cases':
        build(*sys.argv[2:5])
    elif sys.argv[1] == 'freeze':
        freeze(*sys.argv[2:5])
    else:
        sys.exit(1 if compare(*sys.argv[2:5]) else 0)
