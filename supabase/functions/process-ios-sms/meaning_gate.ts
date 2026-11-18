// The server's meaning gate: the parser's meaning (parse.ts messageMeaning),
// plus several movements of one currency in the movement text (dev siblings,
// family d) that the meaning reads as one event. App twin: meaningHoldReason
// in app/lib/domain/capture/validated_capture.dart.
import { separateMovementAmounts, statedTotal } from '../_shared/ai_candidate_validator.ts';
import { dispositionOf, type MessageMeaning } from './message_meaning.ts';
import { isDeclinedText, messageMeaning } from './parse.ts';

/**
 * Follow-up 13 — why an answer [amount] for [text] is never accepted from the
 * parser's meaning, or null when the meaning records:
 * `transaction_not_completed` when the meaning is not completed, or is any
 * other non-record meaning (an over-length text among them) and the whole text
 * carries a not-completed cue; otherwise `message_meaning_<reason>`. A tip/fee
 * form answered at the total the message states is not rejected. App twin:
 * `AiCandidateValidator.meaningRejectionOf`.
 */
export function meaningRejectionOf(
  text: string,
  amount?: number | null,
  meaning: MessageMeaning = messageMeaning(text),
): string | null {
  if (meaning.disposition === 'record') return null;
  if (meaning.kind === 'not_completed' || isDeclinedText(text)) return 'transaction_not_completed';
  if ((meaning.reason === 'tip_component' || meaning.reason === 'total_with_parts') && typeof amount === 'number') {
    const total = statedTotal(text);
    if (total != null && Math.abs(total - amount) < 0.005) return null;
  }
  return `message_meaning_${meaning.reason}`;
}

const SENTENCE_CUT = /[\n!?؟;؛]|\.(?![0-9])/;

/**
 * [meaning] (of [text]), or a review meaning when the text names several
 * movements. A tip/fee form (`tip_component`, `total_with_parts`) whose answered [amount] is the
 * total the message states (dev siblings, family e) records.
 */
export function gatedMeaning(
  text: string,
  meaning: MessageMeaning = messageMeaning(text),
  amount?: number | null,
): MessageMeaning {
  if ((meaning.reason === 'tip_component' || meaning.reason === 'total_with_parts') && typeof amount === 'number') {
    const total = statedTotal(text);
    if (total != null && Math.abs(total - amount) < 0.005) {
      return { ...meaning, kind: 'completed_movement', disposition: dispositionOf('completed_movement'), reason: 'stated_total' };
    }
    return meaning;
  }
  if (meaning.kind !== 'completed_movement' || meaning.footerCount > 0) return meaning;
  // Only sentences the parser itself reads as a movement count (a rule such
  // as "Purchases over SAR 500 will be declined" is not one).
  const movement = text.split(SENTENCE_CUT)
    .filter((s) => /[0-9٠-٩]/.test(s) && messageMeaning(s).disposition === 'record')
    .join('\n');
  if (separateMovementAmounts(movement) == null) return meaning;
  return { ...meaning, kind: 'multiple_events', disposition: dispositionOf('multiple_events'), reason: 'multiple_amounts' };
}
