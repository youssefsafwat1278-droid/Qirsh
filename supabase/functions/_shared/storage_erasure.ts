// Audit H-24 — complete, account-scoped erasure for the user's Storage objects:
// the encrypted backups (`backups`, migration 0010) and the Cloud Sync copy of
// the profile photo (`profile-photos`, migration 20261116210000).
//
// Storage RLS lets a user write objects under their own `<uid>/` folder of
// each of those buckets. The service-role deletion worker bypasses that RLS, so this
// helper must enforce the same ownership boundary itself before every remove.
//
// The sweep is deliberately bounded and convergent:
//   - each remove() call contains at most REMOVE_BATCH_SIZE paths;
//   - each invocation performs at most MAX_REMOVE_BATCHES_PER_RUN removes;
//   - a work-limited invocation returns incomplete/retryable and the durable
//     account-purge queue invokes it again from the prefix root;
//   - there is no nesting-depth cap, so a finite deep tree is eventually
//     traversed instead of permanently failing at an arbitrary depth;
//   - completion requires two consecutive full empty-prefix scans. This catches
//     an object that appears after an earlier scan, while the worker's required
//     post-Auth invocation plus migration 0086's Auth-row Storage write barrier
//     make the terminal scans authoritative: a lingering pre-deletion JWT
//     cannot add another object between proof and dequeue.

export type StorageObject = { name?: string; id?: string | null };

export type BucketLike = {
  list(
    path: string,
    opts?: { limit?: number; offset?: number },
  ): Promise<{ data: StorageObject[] | null; error: { message: string } | null }>;
  remove(
    paths: string[],
  ): Promise<{ data: unknown; error: { message: string } | null }>;
};

export type StorageLike = { from(bucket: string): BucketLike };

export type StorageErasureResult = {
  removed: string[];
  complete: boolean;
  retryable: boolean;
  error?: string;
};

/**
 * Every private bucket keyed by `<uid>/`. Each is swept in order with the same
 * ownership and convergence rules; account deletion is complete only when ALL
 * of them are. A bucket added here without its own `<uid>/` RLS is a bug.
 */
export const ERASURE_BUCKETS = ['backups', 'profile-photos'] as const;
const PAGE_SIZE = 100;
export const REMOVE_BATCH_SIZE = 100;
export const MAX_REMOVE_BATCHES_PER_RUN = 10;
const REQUIRED_EMPTY_SCANS = 2;

function ownedPrefix(userId: string): string {
  return `${userId}/`;
}

function isOwnedPath(path: string, userId: string): boolean {
  return path.startsWith(ownedPrefix(userId));
}

type CollectionResult = { error?: string };

// Collect at most `limit` object paths without mutating Storage during the
// paginated scan. Starting every batch at the root is intentional: removals
// shrink the tree, so repeated bounded invocations make forward progress
// without persisting a traversal cursor. An iterative directory stack avoids
// both call-stack growth and the old permanent depth-limit failure.
async function collectObjectBatch(
  bucket: BucketLike,
  userId: string,
  limit: number,
  paths: Set<string>,
): Promise<CollectionResult> {
  const directories = [userId];

  while (directories.length > 0) {
    const directory = directories.pop()!;
    for (let offset = 0;; offset += PAGE_SIZE) {
      const { data, error } = await bucket.list(directory, { limit: PAGE_SIZE, offset });
      if (error) return { error: `list_prefix(${directory}): ${error.message}` };

      const page = data ?? [];
      for (const object of page) {
        if (!object?.name) continue;

        const path = `${directory}/${object.name}`;
        if (!isOwnedPath(path, userId)) continue;

        if (object.id == null) {
          directories.push(path);
          continue;
        }

        paths.add(path);
        if (paths.size >= limit) return {};
      }

      if (page.length < PAGE_SIZE) break;
    }
  }

  return {};
}

/**
 * Remove the user's objects (every bucket in [ERASURE_BUCKETS]) only from the
 * exact `<userId>/` ownership prefix.
 *
 * `trackedBlobPath` is attempted only when it belongs to that prefix. A path
 * outside the prefix is ignored (never sent to service-role remove), while the
 * owned-prefix sweep still proceeds. Missing objects are idempotent success.
 *
 * `complete: false, retryable: true` means the durable caller must retain its
 * queue row and retry, whether caused by a real Storage error or by this run's
 * bounded work limit. `complete: true` is returned only after two consecutive
 * full scans find no owned object.
 */
export async function eraseBackupObjects(
  storage: StorageLike,
  userId: string,
  trackedBlobPath: string | null,
): Promise<StorageErasureResult> {
  if (!userId || userId.includes('/')) {
    return {
      removed: [],
      complete: false,
      retryable: true,
      error: 'invalid_user_id',
    };
  }

  // Buckets are swept in order; the first incomplete one stops the run (the
  // durable caller retries from the start, and an already-empty bucket costs
  // only its two empty scans). The tracked blob path belongs to `backups`.
  const removed: string[] = [];
  for (const name of ERASURE_BUCKETS) {
    const result = await eraseBucketObjects(
      storage.from(name),
      userId,
      name === 'backups' ? trackedBlobPath : null,
    );
    removed.push(...result.removed);
    if (!result.complete) {
      return {
        removed,
        complete: false,
        retryable: true,
        error: name === 'backups' ? result.error : `${name}: ${result.error}`,
      };
    }
  }
  return { removed, complete: true, retryable: false };
}

async function eraseBucketObjects(
  bucket: BucketLike,
  userId: string,
  trackedBlobPath: string | null,
): Promise<StorageErasureResult> {
  const removed = new Set<string>();
  let pendingTrackedPath = trackedBlobPath && isOwnedPath(trackedBlobPath, userId) ? trackedBlobPath : null;
  let removeBatches = 0;
  let consecutiveEmptyScans = 0;

  while (removeBatches < MAX_REMOVE_BATCHES_PER_RUN) {
    const paths = new Set<string>();
    if (pendingTrackedPath) {
      paths.add(pendingTrackedPath);
      pendingTrackedPath = null;
    }

    const collected = await collectObjectBatch(bucket, userId, REMOVE_BATCH_SIZE, paths);
    if (collected.error) {
      return {
        removed: [...removed],
        complete: false,
        retryable: true,
        error: collected.error,
      };
    }

    // Defense in depth: validate the final removal payload even though both
    // the tracked path and every listed path were checked when inserted.
    const safePaths = [...paths].filter((path) => isOwnedPath(path, userId));
    if (safePaths.length === 0) {
      consecutiveEmptyScans += 1;
      if (consecutiveEmptyScans >= REQUIRED_EMPTY_SCANS) {
        return { removed: [...removed], complete: true, retryable: false };
      }
      continue;
    }

    consecutiveEmptyScans = 0;
    const { error } = await bucket.remove(safePaths);
    if (error) {
      return {
        removed: [...removed],
        complete: false,
        retryable: true,
        error: `remove_objects: ${error.message}`,
      };
    }

    for (const path of safePaths) removed.add(path);
    removeBatches += 1;
  }

  return {
    removed: [...removed],
    complete: false,
    retryable: true,
    error: `work_limit_reached: processed at most ${REMOVE_BATCH_SIZE * MAX_REMOVE_BATCHES_PER_RUN} paths`,
  };
}
