# Qirsh — Terms of Use

**Last updated: 2026-11-17**

By using Qirsh (قِرش) you agree to these terms. If you do not agree, please do
not use the app.

---

## 1. What Qirsh is

Qirsh is a personal finance tracker for iPhone. It reads bank messages that you
share or paste into it, or that a Shortcuts automation you set up passes to it,
and organises them into a private record of your spending. It cannot open your
Messages history and does not read bank app notifications.

You can choose any country in the app, but choosing a country is not a promise
that Qirsh can read your bank's messages. It has been tested with messages from
some banks in Saudi Arabia and Egypt only, and not with every message format.
You can always add transactions manually.

This version of Qirsh shows no advertising.

**Qirsh is not a bank, and is not affiliated with any bank.** It does not hold
money, move money, or execute transactions. It reads messages your bank already
sent you and helps you understand them.

---

## 2. Accuracy — please read this one

Qirsh extracts transaction details from bank messages automatically. Message
formats vary between banks and change without notice, so:

- **Qirsh may misread a message, or miss one entirely.**
- **Your bank's own records are authoritative, not Qirsh.**
- Do not rely on Qirsh for tax, legal, accounting, or any decision where being
  wrong has consequences. Check your bank statement.

The app includes an on-device model that suggests merchants and categories.
Suggestions are suggestions: they never change an amount, a currency, a
transaction's direction, or which account it belongs to — those come only from
the message itself or from you. You can correct any suggestion.

If you turn on Smart Analysis & Cloud Sync, an AI service (Google's Gemini API)
also helps read your messages. AI can be wrong too: a message it cannot read
with confidence is put in your review list rather than saved, and you can
correct, exclude or move any transaction to review.

We have taken care to make extraction accurate and to fail visibly rather than
silently, but we do not warrant that it is complete or correct.

---

## 3. Your responsibilities

- Keep your device and account credentials secure.
- Use Qirsh only with accounts and messages that are yours.
- Do not attempt to disrupt the service or access other users' data.

---

## 4. Your data

Your use of Qirsh is also governed by the [Privacy Policy](./PRIVACY_POLICY.md),
which forms part of these terms.

In short: your financial data stays on your device unless you choose "Agree and
enable" for Smart Analysis & Cloud Sync, you can turn that off at any time
(anything already sent cannot be recalled), and you can delete your account.
Account deletion is final: there is no undo period.

---

## 5. Availability

Qirsh is provided "as is". Cloud features depend on services that may be
unavailable, and we may change or discontinue features.

The app is designed to keep working offline: capture, parsing, categorisation and
all your history function without a network connection. Losing connectivity — or
turning cloud sync off — does not lose your data.

---

## 6. Liability

To the extent permitted by law, we are not liable for indirect or consequential
loss, or for financial decisions made in reliance on the app's output. See §2:
your bank's records are authoritative.

Nothing here excludes liability that cannot lawfully be excluded.

---

## 7. Ending your use

You may stop at any time by deleting the app. Deleting the app does not delete
your Qirsh account or data already in the cloud: to remove them, use "Delete my
account and all my data" in the app (see the Privacy Policy). Account deletion
is final and cannot be undone.

We may suspend accounts that abuse the service or attempt to compromise it.

---

## 8. Changes

Material changes will be announced in the app before taking effect.

---

## 9. Contact

**business@qirsh.site**

---

<!--
  DEPLOYMENT NOTE — not part of the published text.
  The live site is updated only when the owner redeploys it with
  `tools/deploy_site.sh`. Publish together with PRIVACY_POLICY.md and only
  after the V1 app release is live (see the note there).
  The AI-review sentence in §2 depends on the `ai` specialist's final
  behaviour (unsupported AI results go to review) — reconcile before publishing.
  Host at the URL configured in
  `app/lib/core/config/legal_urls.dart`. Governing law is intentionally left for
  the owner to set with legal advice — a jurisdiction invented here would be
  worse than none.
-->
