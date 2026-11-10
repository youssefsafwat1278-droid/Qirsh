import { serviceClient } from '../_shared/capture_auth.ts';
import { sendCapturePush } from '../_shared/apns.ts';
import { clearDeadApnsToken, capturePushContent, isDeadApnsToken } from '../_shared/capture_push.ts';
import { markApnsLogFailed, markApnsLogSent } from '../_shared/notification_logs.ts';
import { isTransientApnsFailure, nextRetryDelayMs } from '../_shared/notification_retry_policy.ts';

type NotificationType = 'new_transaction' | 'needs_review' | 'suspicious_duplicate' | 'received';

const DROP_ERROR_CODES: Record<string, string> = {
  credential_revoked: 'credential_revoked',
  consent_revoked: 'consent_revoked',
  owner_changed: 'owner_changed',
  not_pending: 'capture_not_pending',
  expired: 'capture_expired',
};

export async function processOne(
  supabase: ReturnType<typeof serviceClient>,
  row: {
    id: string;
    notification_log_id: string;
    install_id_hash: string;
    payload_id: string;
    attempt_number: number;
    max_attempts: number;
  },
  sendPush: typeof sendCapturePush = sendCapturePush,
): Promise<'sent' | 'retrying' | 'exhausted' | 'skipped'> {
  // The retry re-runs the terminal fence (§4.1) under FOR SHARE on the device row: the
  // capture must still be pending (not consumed / expired / already sent), the device not
  // revoked, cloud consent on, and the device's CURRENT owner and consent snapshot the ones
  // the result was produced for. A queued notification is never authority to deliver.
  const fence = await supabase.rpc('capture_retry_fence', {
    p_install_id_hash: row.install_id_hash,
    p_payload_id: row.payload_id,
  });
  // Infrastructure failure: leave the claimed row; it becomes reclaimable when stale.
  if (fence.error || !fence.data) return 'retrying';
  const gate = fence.data as {
    allowed: boolean;
    reason?: string;
    apns_token?: string;
    apns_environment?: string;
    notification_type?: NotificationType;
  };

  if (!gate.allowed) {
    const resolveRow = supabase
      .from('notification_retry_queue')
      .update({ resolved_at: new Date().toISOString() })
      .eq('id', row.id);
    // Already sent by a different path: resolve quietly.
    if (gate.reason === 'already_sent') {
      await resolveRow;
      return 'skipped';
    }
    await Promise.all([
      resolveRow,
      markApnsLogFailed(supabase, row.notification_log_id, {
        errorCode: DROP_ERROR_CODES[gate.reason ?? ''] ?? 'retry_unsendable',
        errorReason: 'Retry dropped by the delivery fence',
        retryCount: row.attempt_number,
      }),
    ]);
    return 'exhausted';
  }

  const token = gate.apns_token as string;
  // Read only this fenced capture. A missing/consumed row supplies no details.
  const content = await supabase.from('processed_captures').select('notification')
    .eq('install_id_hash', row.install_id_hash).eq('payload_id', row.payload_id).maybeSingle();
  if (content.error) return 'retrying';
  const result = await sendPush({
    token,
    environment: gate.apns_environment as 'sandbox' | 'production',
    payloadId: row.payload_id,
    notificationLogId: row.notification_log_id,
    ...capturePushContent(content.data?.notification),
    notificationType: gate.notification_type ?? 'new_transaction',
  });

  if (result.ok) {
    await Promise.all([
      supabase
        .from('processed_captures')
        .update({ apns_push_sent_at: new Date().toISOString(), apns_push_error: null })
        .eq('install_id_hash', row.install_id_hash)
        .eq('payload_id', row.payload_id),
      markApnsLogSent(supabase, row.notification_log_id, result.apnsId),
      supabase
        .from('notification_retry_queue')
        .update({ resolved_at: new Date().toISOString() })
        .eq('id', row.id),
    ]);
    console.log(JSON.stringify({
      event: 'notification_sent',
      notificationLogId: row.notification_log_id,
      channel: 'apns',
      attempt: row.attempt_number + 1,
    }));
    return 'sent';
  }

  if (isDeadApnsToken(result)) await clearDeadApnsToken(supabase, row.install_id_hash, token);

  const nextAttemptNumber = row.attempt_number + 1;
  const stillTransient = isTransientApnsFailure(result.httpStatus, result.errorCode);
  const exhausted = !stillTransient || nextAttemptNumber >= row.max_attempts;

  await Promise.all([
    supabase
      .from('processed_captures')
      .update({ apns_push_error: result.reason })
      .eq('install_id_hash', row.install_id_hash)
      .eq('payload_id', row.payload_id),
    markApnsLogFailed(supabase, row.notification_log_id, {
      errorCode: result.errorCode,
      errorReason: result.reason,
      retryCount: nextAttemptNumber,
    }),
    exhausted
      ? supabase
        .from('notification_retry_queue')
        .update({
          attempt_number: nextAttemptNumber,
          last_error_code: result.errorCode,
          resolved_at: new Date().toISOString(),
        })
        .eq('id', row.id)
      : supabase
        .from('notification_retry_queue')
        .update({
          attempt_number: nextAttemptNumber,
          last_error_code: result.errorCode,
          next_attempt_at: new Date(Date.now() + nextRetryDelayMs(nextAttemptNumber)).toISOString(),
        })
        .eq('id', row.id),
  ]);

  console.warn(JSON.stringify({
    event: exhausted ? 'notification_retry_exhausted' : 'notification_retry_scheduled',
    notificationLogId: row.notification_log_id,
    attempt: nextAttemptNumber,
    errorCode: result.errorCode,
  }));
  return exhausted ? 'exhausted' : 'retrying';
}
