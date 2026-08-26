import type { SQL } from "bun";

/** Acquire deterministic transaction-scoped advisory locks for shared mutation boundaries. */
export async function lockMutationKeys(sql: SQL, keys: string[]): Promise<void> {
  const ordered = [...new Set(keys)].sort();
  for (const key of ordered) {
    await sql`SELECT pg_advisory_xact_lock(hashtextextended(${key}, 0))`;
  }
}

/**
 * Hold a transaction-scoped shared fence while cached key material is being populated.
 * Final key revocation takes the matching exclusive fence, so an unwrap that started before
 * revocation either finishes before the durable drain begins or observes the revoked row.
 */
export async function lockSharedMutationKeys(sql: SQL, keys: string[]): Promise<void> {
  const ordered = [...new Set(keys)].sort();
  for (const key of ordered) {
    await sql`SELECT pg_advisory_xact_lock_shared(hashtextextended(${key}, 0))`;
  }
}

export function accountMutationKey(accountId: string): string {
  return `account-mutation:${accountId}`;
}

export async function lockAccountMutations(sql: SQL, accountIds: string[]): Promise<void> {
  await lockMutationKeys(sql, accountIds.map(accountMutationKey));
}

export function draftMutationReceiptKey(accountId: string, operationId: string): string {
  return `draft-mutation-receipt:${accountId}:${operationId}`;
}

export function mediaGroupReceiptKey(accountId: string, clientGroupId: string): string {
  return `media-group-receipt:${accountId}:${clientGroupId}`;
}
