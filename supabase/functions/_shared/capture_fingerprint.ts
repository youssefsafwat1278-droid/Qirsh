// Time component of the capture duplicate fingerprint.
//
// sms_body timestamps stay exact: the bank's own timestamp disambiguates two
// genuinely distinct purchases with the same amount/merchant minutes apart.
//
// Receipt times also stay exact. Stable payload IDs handle delivery retries;
// a broad time window incorrectly collapses legitimate repeat purchases.

export function fingerprintTimeKeys(
  comparisonTimestamp: string,
  _comparisonTimestampSource: string | undefined,
): string[] {
  const ms = new Date(comparisonTimestamp).getTime();
  return [Number.isFinite(ms) ? new Date(ms).toISOString() : comparisonTimestamp];
}
