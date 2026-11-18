#!/usr/bin/env python3
"""Regenerates the STORAGE currency table in lib/domain/finance/currency_scale.dart.

Source: ISO 4217 List One, the maintenance agency's (SIX) XML:
  https://www.six-group.com/dam/download/financial-information/data-center/iso-currrency/lists/list-one.xml
The committed table was generated from the edition with Pblshd="2026-09-17".

Kept: every active code whose minor unit is 0, 2 or 3 and which is not a
fund (IsFund="true"). Left out: funds (BOV, CLF, CHE, ...), codes with no
minor unit ("N.A.": precious metals, XDR, XXX, XTS, ...), and the two
4-decimal units of account (CLF, UYW) that Money cannot hold.

Usage (run from app/):
  python3 -I tool/generate_currency_scale.py /path/to/list-one.xml
It rewrites only the region between the GENERATED markers.
"""
import re
import sys
import xml.etree.ElementTree as ET

TARGET = 'lib/domain/finance/currency_scale.dart'
BEGIN = '  // BEGIN GENERATED (tool/generate_currency_scale.py)\n'
END = '  // END GENERATED\n'


def storage_table(xml_path):
    root = ET.parse(xml_path).getroot()
    published = root.get('Pblshd')
    table = {}
    for entry in root.iter('CcyNtry'):
        code = entry.findtext('Ccy')
        units = entry.findtext('CcyMnrUnts')
        name = entry.find('CcyNm')
        if not code or units not in ('0', '2', '3'):
            continue
        if name is not None and name.get('IsFund') == 'true':
            continue
        scale = int(units)
        if table.setdefault(code, scale) != scale:
            sys.exit(f'{code}: conflicting minor units in source')
    return published, table


def render(published, table):
    lines = [BEGIN, f'  // ISO 4217 List One, published {published}; {len(table)} codes.\n']
    for scale in (3, 0, 2):
        codes = sorted(c for c, s in table.items() if s == scale)
        lines.append(f'  // ── {scale} minor digits ({len(codes)}) ──\n')
        for i in range(0, len(codes), 7):
            row = ' '.join(f"'{c}': {scale}," for c in codes[i:i + 7])
            lines.append(f'  {row}\n')
    lines.append(END)
    return ''.join(lines)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    published, table = storage_table(sys.argv[1])
    with open(TARGET, encoding='utf-8') as f:
        source = f.read()
    pattern = re.compile(re.escape(BEGIN) + '.*?' + re.escape(END), re.S)
    if not pattern.search(source):
        sys.exit('GENERATED markers not found in ' + TARGET)
    out = pattern.sub(lambda _: render(published, table), source, count=1)
    with open(TARGET, 'w', encoding='utf-8') as f:
        f.write(out)
    print(f'{len(table)} codes written from the {published} edition')


if __name__ == '__main__':
    main()
