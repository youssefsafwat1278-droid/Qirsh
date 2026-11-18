// Round 4 (requirement F): a generated parity set. Synthetic texts are built
// from templates x people x merchants x number forms (Western and
// Arabic-Indic digits); the server's output for each is written to
// fixtures/sms_redaction_parity_cases.json, which the Dart test
// (app/test/engine/privacy/sms_name_minimization_test.dart) and the Swift
// test (RunnerTests) read and must reproduce byte for byte.
//
// Regenerate after a deliberate rule change:
//   UPDATE_REDACTION_PARITY=1 deno test --allow-read --allow-env --allow-write _shared/sms_redaction_parity_test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { redactPii, redactThirdPartyNames } from './sms_redaction.ts';

const sanitize = (t: string) => redactThirdPartyNames(redactPii(t)).trim();
const FIXTURE = new URL('./fixtures/sms_redaction_parity_cases.json', import.meta.url);

const PEOPLE = ['Nadir Zaki', 'LAYLA H. MANSOUR', 'Dr. Tariq Aziz', 'نادر زكي', 'ليلى حسن منصور'];
const MERCHANTS = ['Example Bookstore', 'EXAMPLE MARKETS', 'Example Trading LLC', 'مكتبة المثال', 'شركة المثال للتجارة'];
const arabicIndic = (s: string) => s.replace(/[0-9]/g, (d) => String.fromCharCode(0x0660 + Number(d)));
// [amount, own suffix, third-party suffix, third-party long number, code]
const NUMBERS: [string, string, string, string, string][] = [
  ['85.00', '*4521', '*9876', '60181590', '482913'],
  ['1,250.50', '***1234', '****7788', 'SA0380000000608010167519', '7712'],
  [arabicIndic('4829'), '*' + arabicIndic('4521'), arabicIndic('9876'), arabicIndic('60181590'), arabicIndic('482913')],
];

interface Template {
  /** {P} person, {M} merchant, {A} amount, {O} own suffix, {T} third-party suffix, {L} long number, {C} code. */
  text: string;
  /** What must be gone / must stay, checked here before the fixture is trusted. */
  drop: string;
  keep: string;
}
const TEMPLATES: Template[] = [
  { text: 'Transfer of SAR {A} to {P} from your account {O} completed', drop: 'PT', keep: 'AO' },
  { text: 'Transfer of SAR {A} to {M} from your account {O} completed', drop: '', keep: 'AOM' },
  { text: 'SAR {A} received from {P} into your account {O}', drop: 'P', keep: 'AO' },
  { text: 'From {P}: SAR {A} received', drop: 'P', keep: 'A' },
  { text: 'SAR {A} paid to {P}', drop: 'P', keep: 'A' },
  { text: 'Card {O}: SAR {A} paid to {M}', drop: '', keep: 'AOM' },
  { text: 'Payment of SAR {A} to {P} via Mada', drop: 'P', keep: 'A' },
  { text: 'Purchase of SAR {A} at {M} with card {O}. Name: {P}', drop: 'P', keep: 'AOM' },
  { text: 'Purchase To: {M} SAR {A} card {O}', drop: '', keep: 'AOM' },
  { text: 'Refund of SAR {A} from {M} credited to your card {O}', drop: '', keep: 'AOM' },
  { text: 'Bill payment SAR {A} to {M} from your account {O}', drop: '', keep: 'AOM' },
  { text: 'Bill payment SAR {A} to account of {P}', drop: 'P', keep: 'A' },
  { text: 'SAR {A} transferred to beneficiary account {T}. Beneficiary: {P}', drop: 'PT', keep: 'A' },
  { text: 'SAR {A} sent to account {T} ({P}) from your account {O}', drop: 'PT', keep: 'AO' },
  { text: 'SAR {A} sent to {P} account {L} from your card {O}', drop: 'PL', keep: 'AO' },
  { text: 'Customer {P}: your code is {C}. Do not share it. Purchase SAR {A} at {M}', drop: 'PC', keep: 'AM' },
  { text: 'Use {C} to confirm your payment of SAR {A} to {M}', drop: 'C', keep: 'A' },
  { text: '{P} sent you SAR {A}', drop: 'P', keep: 'A' },
  { text: 'تم تحويل {A} ريال إلى {P} من حسابك {O} بنجاح', drop: 'P', keep: 'AO' },
  { text: 'تم تحويل {A} ريال إلى حساب المستفيد {T} من حسابك {O}', drop: 'T', keep: 'AO' },
  { text: 'حوالة واردة {A} ريال من {P} إلى حسابك {O}', drop: 'P', keep: 'AO' },
  { text: 'حوالة واردة {A} ريال من حساب {T} إلى حسابك {O}', drop: 'T', keep: 'AO' },
  { text: 'شراء {A} ريال إلى {M} بطاقة {O}', drop: '', keep: 'AOM' },
  { text: 'شراء عبر نقاط البيع {A} ريال لدى {M} بطاقة {O}. حامل البطاقة {P}', drop: 'P', keep: 'AOM' },
  { text: 'استرداد {A} ريال من {M} إلى بطاقتك {O}', drop: '', keep: 'AOM' },
  { text: 'سداد فاتورة {A} ريال إلى {M} من حسابك {O}', drop: '', keep: 'AOM' },
  { text: 'دفع {A} ريال إلى حساب {P} رقم {L}', drop: 'PL', keep: 'A' },
  { text: 'العميل {P}: رمز التحقق هو {C} لعملية شراء بمبلغ {A} ريال لدى {M}', drop: 'PC', keep: 'AM' },
  { text: 'أرسل لك {P} {A} ريال', drop: 'P', keep: 'A' },
];

/** A merchant is kept only where its name is in the script the template reads it in. */
function generate(): { raw: string; drop: string[]; keep: string[] }[] {
  const out: { raw: string; drop: string[]; keep: string[] }[] = [];
  TEMPLATES.forEach((t, ti) => {
    PEOPLE.forEach((p, pi) => {
      // One merchant and one number form per (template, person): a rotating
      // cover of every merchant and form rather than the full product.
      for (const k of [0, 1]) {
        const m = MERCHANTS[(ti + pi + k) % MERCHANTS.length];
        const [a, o, tp, l, c] = NUMBERS[(ti + pi + 2 * k) % NUMBERS.length];
        const fill: Record<string, string> = { P: p, M: m, A: a, O: o, T: tp, L: l, C: c };
        const raw = t.text.replace(/\{([A-Z])\}/g, (_, key) => fill[key]);
        const used = (keys: string) => [...keys].filter((key) => t.text.includes(`{${key}}`)).map((key) => fill[key]);
        out.push({ raw, drop: used(t.drop).flatMap((v) => v.split(/[ .]+/).filter((w) => w.length > 2)), keep: used(t.keep) });
      }
    });
  });
  return out;
}

Deno.test('generated parity set: every person, number and code is gone and every merchant, amount and own suffix stays', () => {
  const cases = generate();
  assert(cases.length >= 250, `${cases.length} generated texts`);
  const failures: string[] = [];
  for (const c of cases) {
    const out = sanitize(c.raw);
    for (const d of c.drop) if (out.includes(d)) failures.push(`"${d}" survived in ${JSON.stringify(out)}`);
    for (const k of c.keep) if (!out.includes(k)) failures.push(`"${k}" lost in ${JSON.stringify(out)} (from ${JSON.stringify(c.raw)})`);
    if (sanitize(out) !== out) failures.push(`not idempotent: ${JSON.stringify(out)}`);
  }
  assertEquals(failures, []);
});

Deno.test('generated parity set: the fixture the device and the Shortcut read is the server output', () => {
  const rows = generate().map((c) => ({ raw: c.raw, expected: sanitize(c.raw) }));
  const text = '[\n' + rows.map((r) => ' ' + JSON.stringify(r)).join(',\n') + '\n]\n';
  if (Deno.env.get('UPDATE_REDACTION_PARITY') === '1') Deno.writeTextFileSync(FIXTURE, text);
  assertEquals(Deno.readTextFileSync(FIXTURE), text);
});
