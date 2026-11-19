// Review fix AR-02 / AR-07: redaction never removes what a message says
// happened. For EVERY not-completed, awaited, pending, future, negation and
// hypothetical cue of the parser's vocabulary (`process-ios-sms/
// parser_rules.json`, read live, so a cue the parser gains later is covered or
// this test fails), the cue is placed right after a beneficiary or sender
// name. The redacted text must still carry the cue, must not carry the name,
// and must have the same meaning as the raw text.
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { messageMeaning } from '../process-ios-sms/parse.ts';
import { redactPii, redactThirdPartyNames } from './sms_redaction.ts';

const rules = JSON.parse(
  Deno.readTextFileSync(new URL('../process-ios-sms/parser_rules.json', import.meta.url)),
);
const M = rules.messageMeaning as Record<string, unknown>;
const list = (v: unknown) => (Array.isArray(v) ? v.filter((x) => typeof x === 'string') as string[] : []);
const CUES = [
  ...new Set([
    ...list(rules.declinedKeywords),
    ...list(rules.stateCueAwaitedWords),
    ...list(rules.stateCueHypotheticalMarkers),
    ...list(rules.stateCueFutureMarkers),
    ...list(rules.stateCueNegationMarkers),
    ...list(M.futureMarkers),
    ...list(M.futureTense),
    ...list(M.tenseMarkers),
    ...list(M.dueMarkers),
    ...list(M.pendingWords),
  ]),
];
const DATE_WORDS = [
  'yesterday', 'today', 'tomorrow', 'tonight', 'this morning', 'last night', 'on Monday', 'last week', 'just now',
  'أمس', 'اليوم', 'غدا', 'البارحة', 'الآن', 'مساء اليوم', 'يوم الخميس', 'الأسبوع الماضي', 'صباحا',
];
const ARABIC = /[؀-ۿ]/u;
const TEMPLATES: { arabic: boolean; text: string; name: string[] }[] = [
  { arabic: true, text: 'حوالة 152 ريال إلى هاني عادل {cue}', name: ['هاني', 'عادل'] },
  { arabic: true, text: 'حوالة واردة 152 ريال من هاني عادل {cue}', name: ['هاني', 'عادل'] },
  { arabic: true, text: 'تم تحويل 152 ريال لصالح عبد العزيز القحطاني {cue}', name: ['عبد', 'العزيز', 'القحطاني'] },
  { arabic: false, text: 'Transfer of SAR 148.00 to Fadi Nasser {cue}', name: ['Fadi', 'Nasser'] },
  { arabic: false, text: 'Transfer SAR 148.00 To: Fadi Nasser {cue}', name: ['Fadi', 'Nasser'] },
  { arabic: false, text: 'SAR 148.00 transfer from Fadi Nasser {cue}', name: ['Fadi', 'Nasser'] },
];
const sanitize = (t: string) => redactThirdPartyNames(redactPii(t)).trim();

Deno.test('cue vocabulary: the parser lists are there', () => {
  assert(CUES.length > 200, `${CUES.length} cues`);
  assert(CUES.some((c) => ARABIC.test(c)) && CUES.some((c) => !ARABIC.test(c)));
});

Deno.test('cue vocabulary: every cue after a name survives redaction and keeps the meaning', () => {
  const failures: string[] = [];
  let checked = 0;
  for (const cue of [...CUES, ...DATE_WORDS]) {
    for (const t of TEMPLATES.filter((x) => x.arabic === ARABIC.test(cue))) {
      const raw = t.text.replace('{cue}', cue);
      const out = sanitize(raw);
      checked++;
      if (!out.includes(cue)) failures.push(`cue lost: ${JSON.stringify(raw)} -> ${JSON.stringify(out)}`);
      // Every template is a transfer: the name goes even when the cue carries
      // a purchase, refund or bill word (the transfer reading wins).
      for (const n of t.name) {
        if (out.includes(n)) failures.push(`name kept: ${JSON.stringify(raw)} -> ${JSON.stringify(out)}`);
      }
      const before = messageMeaning(raw);
      const after = messageMeaning(out);
      if (before.kind !== after.kind || before.disposition !== after.disposition || before.reason !== after.reason) {
        failures.push(
          `meaning ${before.kind}:${before.reason} became ${after.kind}:${after.reason}: ${JSON.stringify(raw)} -> ${JSON.stringify(out)}`,
        );
      }
    }
  }
  assert(checked > 800, `${checked} texts`);
  assertEquals(failures, []);
});
