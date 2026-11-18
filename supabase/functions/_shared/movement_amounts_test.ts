// Dev siblings d/e: several movements in one message, and the total a message
// states for one movement made of parts. The device runs the same fixture
// (app/test/engine/ai/movement_amounts_test.dart) and must agree.
import { assertEquals } from 'jsr:@std/assert@1';
import { separateMovementAmounts, statedTotal } from './ai_candidate_validator.ts';

const CASES: { id: string; text: string; separate: number[] | null; statedTotal: number | null }[] = JSON.parse(
  Deno.readTextFileSync(new URL('./fixtures/movement_amount_cases.json', import.meta.url)),
);

for (const c of CASES) {
  Deno.test(`movement amounts: ${c.id}`, () => {
    assertEquals(separateMovementAmounts(c.text), c.separate);
    assertEquals(statedTotal(c.text), c.statedTotal);
  });
}
