#!/usr/bin/env python3
"""Fills the date/time placeholders of the held-out set for one run.

Each message is 'received' 2 hours before the run, and its written date/time
is the sender's local clock a few minutes earlier, so every date check the
code makes (31-day window, future guard) sees a fresh message.

usage: expand.py <messages.jsonl> <out.json>
"""
import json
import sys
from datetime import datetime, timedelta, timezone

TZ = {'SA': 180, 'KW': 180, 'QA': 180, 'BH': 180, 'EG': 120, 'AE': 240,
      'OM': 240, 'INTL': 0}
MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
       'Nov', 'Dec']


def main(src, dst):
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    received = now - timedelta(hours=2)
    out = []
    for line in open(src, encoding='utf-8'):
        r = json.loads(line)
        off = TZ[r['region']]
        local = received + timedelta(minutes=off - 3)
        text = (r['text']
                .replace('{D1}', local.strftime('%Y-%m-%d'))
                .replace('{D2}', local.strftime('%d/%m/%Y'))
                .replace('{D4}', f'{local.day:02d} {MON[local.month - 1]}')
                .replace('{T}', local.strftime('%H:%M')))
        r.update(text=text, received_at=received.isoformat().replace('+00:00', 'Z'),
                 tz_offset=off)
        out.append(r)
    json.dump({'run_at': now.isoformat(), 'messages': out},
              open(dst, 'w', encoding='utf-8'), ensure_ascii=False)


if __name__ == '__main__':
    main(*sys.argv[1:3])
