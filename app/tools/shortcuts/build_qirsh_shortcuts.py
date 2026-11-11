#!/usr/bin/env python3
"""Builds one signed Apple Shortcut per bank-SMS keyword from the real QIRSH template.

qirsh_template.plist is the published QIRSH shortcut
(https://www.icloud.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20) exported as XML:
a "When I receive a message containing EGP" trigger feeding Shortcut Input and its
Sender into Qirsh's PostBankStatusIntent. Each variant changes ONLY the trigger's
Message-contains text and the two UUIDs; the intent call is copied byte for byte.

Usage (macOS, from app/):
    python3 tools/shortcuts/build_qirsh_shortcuts.py [--out DIR] [--unsigned]

Signing uses Apple's `shortcuts sign --mode anyone`, which needs the Mac signed in
to iCloud. Publishing an iCloud link stays manual: import each file into Shortcuts,
then Share > Copy iCloud Link, and paste it into qirshShortcutKeywords.
"""

import argparse
import plistlib
import subprocess
import sys
import uuid
from pathlib import Path

# Must match qirshShortcutKeywords in lib/features/onboarding/shortcut_setup_actions.dart.
KEYWORDS = ['EGP', 'جم', 'جنيه', 'ج.م', 'USD', 'EUR', 'SAR', 'ر.س', 'AED', 'د.إ',
            'KWD', 'د.ك']

HERE = Path(__file__).resolve().parent


def variant(template: dict, keyword: str) -> dict:
    shortcut = plistlib.loads(plistlib.dumps(template))  # deep copy
    triggers = shortcut['WFWorkflowTriggers']
    assert len(triggers) == 1 and triggers[0]['WFTriggerIdentifier'] == 'WFMessageTrigger'
    conditions = triggers[0]['WFTriggerSerializedParameters']['WFMessageConditions']
    filters = conditions['Value']['WFActionParameterFilterTemplates']
    assert len(filters) == 1 and filters[0]['Property'] == 'Message'
    filters[0]['Values']['Text'] = keyword
    triggers[0]['WFTriggerUUID'] = str(uuid.uuid4()).upper()
    for action in shortcut['WFWorkflowActions']:
        action['WFWorkflowActionParameters']['UUID'] = str(uuid.uuid4()).upper()
    return shortcut


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', default=str(HERE.parents[1] / 'build' / 'qirsh_shortcuts'))
    parser.add_argument('--unsigned', action='store_true')
    args = parser.parse_args()

    template = plistlib.loads((HERE / 'qirsh_template.plist').read_bytes())
    out = Path(args.out)
    (out / 'unsigned').mkdir(parents=True, exist_ok=True)
    for keyword in KEYWORDS:
        name = f'Qirsh {keyword}'
        unsigned = out / 'unsigned' / f'{name}.shortcut'
        unsigned.write_bytes(plistlib.dumps(variant(template, keyword), fmt=plistlib.FMT_BINARY))
        if args.unsigned:
            print(unsigned)
            continue
        signed = out / f'{name}.shortcut'
        result = subprocess.run(
            ['shortcuts', 'sign', '--mode', 'anyone', '--input', str(unsigned), '--output', str(signed)],
            capture_output=True, text=True)
        if result.returncode != 0:
            print(f'signing failed for {name}: {result.stderr.strip()}', file=sys.stderr)
            return 1
        print(signed)
    return 0


if __name__ == '__main__':
    sys.exit(main())
