// account-deletion-worker - DRAFT, NOT DEPLOYED. Scheduled every 5 minutes by a
// guarded pg_cron job. Auth: dedicated ACCOUNT_DELETION_WORKER_SECRET (never the
// service-role key), fail-closed when unset. Not evaluated by tests.

import { buildDeletionRuntime } from '../_shared/account_deletion_runtime.ts';
import { createWorkerHandler } from './handler.ts';

let runtime: ReturnType<typeof buildDeletionRuntime> | null = null;

const handle = createWorkerHandler({
  coordinator: async () => {
    runtime ??= buildDeletionRuntime({ retryScheduledClaim: true }).catch((e) => {
      runtime = null;
      throw e;
    });
    return (await runtime).coordinator;
  },
  workerSecret: Deno.env.get('ACCOUNT_DELETION_WORKER_SECRET') ?? '',
  workerId: `worker-${crypto.randomUUID()}`,
});

Deno.serve(handle);
