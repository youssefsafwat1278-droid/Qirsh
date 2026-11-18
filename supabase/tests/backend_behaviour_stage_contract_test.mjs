// V1-013 — the backend behaviour stage is opt-in, reported truthfully, and its
// runner can only ever touch a local, dedicated Postgres.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const gates = readFileSync(new URL('tools/ci_gates.sh', root), 'utf8');
const runner = new URL('tools/backend_behaviour.sh', root).pathname;

test('ci_gates runs the stage only when BACKEND_PG_HOST is set and never counts not-run as a pass', () => {
  assert.match(gates, /if \[ -n "\$\{BACKEND_PG_HOST:-\}" \]; then/);
  assert.match(gates, /bash "\$ROOT\/tools\/backend_behaviour\.sh"/);
  assert.match(gates, /backend_state="not-run"/);
  assert.match(gates, /\\"backend_behaviour\\":\\"\$backend_state\\"/);
  // The not-run branch must not call ok(): read the else-branch text.
  const elseBranch = gates.split('backend behaviour NOT RUN')[0].split('else').pop();
  assert.doesNotMatch(elseBranch, /\bok /);
});

for (const host of ['db.example.supabase.co', '10.0.0.5', 'postgres.internal']) {
  test(`runner refuses a non-local host (${host}) before connecting`, () => {
    const r = spawnSync('bash', [runner], {
      env: { PATH: process.env.PATH, BACKEND_PG_HOST: host },
      encoding: 'utf8',
    });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /REFUSING: BACKEND_PG_HOST must be local/);
  });
}

test('runner refuses without BACKEND_PG_HOST', () => {
  const r = spawnSync('bash', [runner], { env: { PATH: process.env.PATH }, encoding: 'utf8' });
  assert.notEqual(r.status, 0);
});

test('runner refuses a cluster that is not dedicated', () => {
  const src = readFileSync(runner, 'utf8');
  assert.match(src, /REFUSING: cluster is not dedicated/);
  assert.match(src, /datname not like 'qirsh_bb_%'/);
});
