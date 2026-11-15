// PostgREST rejected this JWT before the claim ran. The Edge Runtime and the
// gateway clocks can briefly disagree when the platform issues a fresh key.
export async function retryWorkerClaim<T extends { error: { code?: string; message?: string } | null }>(
  claim: () => PromiseLike<T>,
  delay: (ms: number) => Promise<void> = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
): Promise<T> {
  const first = await claim();
  if (
    first.error?.code !== 'PGRST303' ||
    first.error.message?.trim().toLowerCase() !== 'jwt issued at future'
  ) return first;
  await delay(2000);
  return await claim();
}
