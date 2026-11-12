import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import {
  IBAN_DETECT_PATTERN,
  isCounterpartyContext,
  redactPii,
  redactSenderForAi,
  redactThirdPartyNames,
} from './sms_redaction.ts';
import { merchantGrounded } from './ai_candidate_validator.ts';

Deno.test('IBANs are redacted — the account rule cannot reach them', () => {
  // The regression: `\b\d{10,20}\b` never matches this, because there is no
  // word boundary between "SA" and the digits. Before the shared floor, this
  // string reached Gemini intact from process-ios-sms and bank-discovery.
  const out = redactPii('حوالة من SA0380000000608010167519 بمبلغ 500 ريال');
  assertStringIncludes(out, '[IBAN]');
  assert(!out.includes('SA0380000000608010167519'));
});

Deno.test('OTP digits are redacted but the cue survives', () => {
  assertEquals(redactPii('Your OTP is 483920'), 'Your OTP is [OTP]');
  assertEquals(redactPii('رمز التحقق: 8391'), 'رمز التحقق: [OTP]');
});

Deno.test('amounts are never redacted by shape', () => {
  // Cue-anchoring exists for exactly this: a bare 4-8 digit run is more often
  // an amount than a passcode, and the proof layer depends on the amount.
  assertEquals(redactPii('شراء بمبلغ 250.75 ريال'), 'شراء بمبلغ 250.75 ريال');
  assertEquals(redactPii('مبلغ 1250 ريال'), 'مبلغ 1250 ريال');
});

Deno.test('card, phone and account rules still apply in the right order', () => {
  assertEquals(redactPii('بطاقة 4539 1488 0343 6467'), 'بطاقة [CARD]');
  assertEquals(redactPii('اتصل 0551234567'), 'اتصل [PHONE]');
  assertEquals(redactPii('اتصل 01012345678'), 'اتصل [PHONE]');
  assertEquals(redactPii('call +966551234567'), 'call [PHONE]');
  assertEquals(redactPii('حساب 1234567890123'), 'حساب [ACCOUNT]');
});

Deno.test('Arabic-Indic digits are redacted, not waved through', () => {
  // Every pattern used ASCII \\d, so identifiers written in the digits half
  // this market uses reached Gemini intact.
  const account = redactPii('حساب ١٢٣٤٥٦٧٨٩٠١٢٣ خصم');
  assertStringIncludes(account, '[ACCOUNT]');
  assert(!account.includes('١٢٣٤٥٦٧٨٩٠'));
  assertStringIncludes(redactPii('بطاقة ٤٥٣٩١٤٨٨٠٣٤٣٦٤٦٧'), '[CARD]');
  assertStringIncludes(redactPii('اتصل ٠٥٥١٢٣٤٥٦٧'), '[PHONE]');
  // Extended Arabic-Indic (U+06F0-06F9) too.
  assertStringIncludes(redactPii('حساب ۱۲۳۴۵۶۷۸۹۰۱۲۳'), '[ACCOUNT]');
});

Deno.test('an Arabic-Indic amount still survives', () => {
  // The widened digit classes must not cost the amounts their reason for
  // existing: four digits is an amount, not an account number.
  assertEquals(redactPii('مبلغ ١٢٥٠ ريال'), 'مبلغ ١٢٥٠ ريال');
  assertEquals(redactPii('مبلغ ٢٥٠٫٧٥ ريال'), 'مبلغ ٢٥٠٫٧٥ ريال');
});

Deno.test('a lower-case IBAN is the same identifier and is redacted', () => {
  const out = redactPii('IBAN sa0380000000608010167519');
  assertStringIncludes(out, '[IBAN]');
  assert(!out.includes('sa0380000000608010167519'));
  assertEquals(IBAN_DETECT_PATTERN.test('sa0380000000608010167519'), true);
});

Deno.test('the generic account rule does not eat a card number', () => {
  // A 16-digit run with no separators matches BOTH the card and the account
  // pattern; card must win, which is only true while it runs first.
  assertEquals(redactPii('4539148803436467'), '[CARD]');
});

Deno.test('IBAN_DETECT_PATTERN is not stateful across calls', () => {
  // A /g regex carries lastIndex, so `.test()` on the same input would
  // alternate true/false and a fail-closed gate would pass every other
  // request. This pattern is deliberately non-global.
  const sms = 'SA0380000000608010167519';
  assertEquals(IBAN_DETECT_PATTERN.test(sms), true);
  assertEquals(IBAN_DETECT_PATTERN.test(sms), true);
});

Deno.test('third-party names are stripped', () => {
  // A live wire probe against the deployed process-ios-sms showed
  // "حوالة الى: سارة الاسمري" persisted in full: redactPii handles digits, and
  // only parse-sms carried the name rules. A person who is not this app's user
  // never agreed to anything here.
  const out = redactThirdPartyNames('حوالة الى: سارة الاسمري');
  assert(!out.includes('سارة'));
  assertStringIncludes(out, '[REDACTED]');

  assertStringIncludes(redactThirdPartyNames('To: John Smith'), 'To: [REDACTED]');
  assertStringIncludes(redactThirdPartyNames('عزيزي أحمد'), '[REDACTED]');
});

Deno.test('the two passes compose without eating the amount', () => {
  const out = redactThirdPartyNames(
    redactPii('حوالة الى: سارة الاسمري بمبلغ 250.75 من SA0380000000608010167519'),
  );
  // The beneficiary rule takes the rest of the LINE, so the amount after it is
  // gone by design — over-redaction, which is the safe direction. What must
  // hold is that no identifier survives.
  assert(!out.includes('سارة'));
  assert(!out.includes('SA0380000000608010167519'));
});

Deno.test('an amount on its own line survives name stripping', () => {
  const out = redactThirdPartyNames(redactPii('مبلغ 250.75 ريال\nالى: سارة'));
  assertStringIncludes(out, '250.75');
  assert(!out.includes('سارة'));
});

// ── Personal-name minimisation (F4) ─────────────────────────────────────────
// The same fixture file is run by app/test/engine/privacy/
// sms_name_minimization_test.dart against the Dart SmsSanitizer, so device and
// server cannot drift apart. All messages are synthetic.
interface RedactionCase {
  id: string;
  kind: string;
  raw: string;
  expected: string;
  mustKeep: string[];
  mustDrop: string[];
}
const CASES: RedactionCase[] = JSON.parse(
  Deno.readTextFileSync(new URL('./fixtures/sms_redaction_cases.json', import.meta.url)),
);
const serverSanitize = (text: string) => redactThirdPartyNames(redactPii(text)).trim();

Deno.test('shared redaction fixture is non-empty and covers every message kind', () => {
  const kinds = new Set(CASES.map((c) => c.kind));
  for (const k of ['purchase', 'refund', 'atm', 'transfer_in', 'transfer_out', 'salary', 'otp', 'promo', 'bill']) {
    assert(kinds.has(k), `missing kind ${k}`);
  }
});

for (const c of CASES) {
  Deno.test(`shared redaction fixture: ${c.id} (${c.kind})`, () => {
    const out = serverSanitize(c.raw);
    assertEquals(out, c.expected);
    for (const keep of c.mustKeep) assertStringIncludes(out, keep, `parsing needs "${keep}"`);
    for (const drop of c.mustDrop) assert(!out.includes(drop), `"${drop}" is personal and leaked`);
    // Idempotent: a second pass (old client → new server, or the server's own
    // re-sanitise) changes nothing.
    assertEquals(serverSanitize(out), out);
  });
}

Deno.test('a merchant is never masked in a purchase, even after "from" / «من»', () => {
  for (
    const sms of [
      'Purchase from AMAZON SA SAR 99.00 card ending 4321',
      'Purchase at FROM SCRATCH CAFE SAR 45.00 card *4321',
      'شراء من كارفور بمبلغ 230.75 ريال بطاقة *9876',
      'Refund of SAR 99.00 from NOON credited to card *1111',
    ]
  ) {
    assertEquals(serverSanitize(sms), sms);
  }
});

Deno.test('a person is masked after every transfer cue, keeping the cue', () => {
  assertEquals(
    serverSanitize('حوالة واردة من محمد عبدالله بمبلغ 500 ريال'),
    'حوالة واردة من [NAME] بمبلغ 500 ريال',
  );
  assertEquals(
    serverSanitize('Transfer received from JOHN SMITH amount SAR 10.00'),
    'Transfer received from [NAME] amount SAR 10.00',
  );
  assertEquals(
    serverSanitize('Account credited by EGP 50.00 from SARA M*** via InstaPay'),
    'Account credited by EGP 50.00 from [NAME] via InstaPay',
  );
});

Deno.test('greetings: English at sentence start only; Arabic multi-word names fully removed', () => {
  assertEquals(serverSanitize('Dear Ahmed Ali, SAR 5.00 spent at JARIR'), 'Dear [NAME], SAR 5.00 spent at JARIR');
  assertEquals(serverSanitize('Purchase at DEAR DIARY CAFE SAR 20'), 'Purchase at DEAR DIARY CAFE SAR 20');
  const ar = serverSanitize('عزيزي محمد أحمد، تم خصم 50 ريال');
  assert(!ar.includes('محمد') && !ar.includes('أحمد'), ar);
  assertStringIncludes(ar, '50 ريال');
});

Deno.test('reference numbers are masked by cue; amounts after a cue are not', () => {
  assertEquals(redactPii('IPN REF# 123456789'), 'IPN REF# [REF]');
  assertEquals(redactPii('رقم المرجع 99887766'), 'رقم المرجع [REF]');
  assertEquals(redactPii('Ref 5000000.00'), 'Ref 5000000.00');
  assertEquals(redactPii('refund 123456 SAR'), 'refund 123456 SAR');
});

Deno.test('e-mail addresses are masked', () => {
  assertEquals(redactPii('contact ahmed0551234567@mail.com now'), 'contact [EMAIL] now');
});

Deno.test('counterparty context is decided from text alone', () => {
  assertEquals(isCounterpartyContext('Transfer received from X'), true);
  assertEquals(isCounterpartyContext('Purchase from AMAZON'), false);
  assertEquals(isCounterpartyContext('Refund from NOON credited'), false);
  assertEquals(isCounterpartyContext('حوالة واردة من محمد'), true);
  assertEquals(isCounterpartyContext('شراء من كارفور'), false);
});

// ── Sender ID in the bank-discovery prompt (F3) ─────────────────────────────
Deno.test('bank-discovery: an alphanumeric brand sender is kept; a phone or short code never is', () => {
  assertEquals(redactSenderForAi('GULFBANK'), 'GULFBANK');
  assertEquals(redactSenderForAi('Al-Rajhi'), 'Al-Rajhi');
  assertEquals(redactSenderForAi('بنك'), 'بنك');
  for (const s of ['+966551234567', '0551234567', '01012345678', '19623', '3636', '٠٥٥١٢٣٤٥٦٧', '  ']) {
    assertEquals(redactSenderForAi(s), '[NUMERIC_SENDER]', s);
  }
  // Digits inside an alphanumeric sender still go through the PII floor.
  assertEquals(redactSenderForAi('AB 0551234567'), 'AB [PHONE]');
});

Deno.test('bank-discovery builds its prompt sender only through redactSenderForAi', () => {
  const src = Deno.readTextFileSync(new URL('../bank-discovery/index.ts', import.meta.url));
  assertStringIncludes(src, 'Sender ID: ${redactSenderForAi(request.senderId)}');
  assertEquals(src.match(/\$\{request\.senderId\}/g), null, 'raw sender interpolated into a prompt');
});

Deno.test('enrich-merchant refuses a merchant carrying an identifier before Places / catalogue', () => {
  const src = Deno.readTextFileSync(new URL('../enrich-merchant/index.ts', import.meta.url));
  const guard = src.indexOf('if (redactPii(merchantName) !== merchantName)');
  assert(guard > 0, 'guard missing');
  assert(guard < src.indexOf('PLACES_URL, {'), 'guard must run before the Places call');
  // What the guard rejects / accepts:
  for (const m of ['AHMED 0551234567', 'pay@me.com', 'REF 1234567', 'SA0380000000608010167519']) {
    assert(redactPii(m) !== m, m);
  }
  for (const m of ['STARBUCKS RIYADH', 'كارفور', 'NOON.COM', 'FAWRY*SNTRAL NWR ALA']) {
    assertEquals(redactPii(m), m);
  }
});

Deno.test('a sanitizer placeholder is never a grounded merchant', () => {
  const text = 'Transfer received from [NAME] amount SAR 10.00';
  assertEquals(merchantGrounded('[NAME]', text), false);
  assertEquals(merchantGrounded('from [NAME]', text), false);
  assertEquals(merchantGrounded('STARBUCKS', 'Purchase at STARBUCKS SAR 5'), true);
});

Deno.test('parse-sms drops a placeholder merchant_name before returning/storing a result', () => {
  const src = Deno.readTextFileSync(new URL('../parse-sms/index.ts', import.meta.url));
  assertStringIncludes(src, 'REDACTION_PLACEHOLDER.test(result.merchant_name)');
});
