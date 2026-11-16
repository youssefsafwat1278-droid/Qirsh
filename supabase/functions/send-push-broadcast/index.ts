import { handleSendPushBroadcast } from './send.ts';

if (import.meta.main) Deno.serve((req) => handleSendPushBroadcast(req));
