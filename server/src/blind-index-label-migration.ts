import type { SQL } from "bun";

const MAX_BATCH_SIZE = 10_000;

export type BlindIndexLabelBackfillDomain =
  | "devices"
  | "otp-network"
  | "call-network"
  | "message-preview-url";

async function backfillDomainBatch(
  sql: SQL,
  domain: BlindIndexLabelBackfillDomain,
  requestedBatchSize: number,
): Promise<number> {
  const batchSize = Math.max(1, Math.min(MAX_BATCH_SIZE, requestedBatchSize));
  switch (domain) {
  case "devices":
    return Number((await sql`
      WITH batch AS MATERIALIZED (
        SELECT id FROM devices
        WHERE (push_token_hash IS NOT NULL AND push_token_hash_key_id IS NULL)
           OR (voip_push_token_hash IS NOT NULL AND voip_push_token_hash_key_id IS NULL)
        ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${batchSize}
      ), updated AS (
        UPDATE devices target SET
          push_token_hash_key_id = CASE
            WHEN target.push_token_hash IS NOT NULL
              AND target.push_token_hash_key_id IS NULL THEN 'legacy-v1'
            ELSE target.push_token_hash_key_id END,
          voip_push_token_hash_key_id = CASE
            WHEN target.voip_push_token_hash IS NOT NULL
              AND target.voip_push_token_hash_key_id IS NULL THEN 'legacy-v1'
            ELSE target.voip_push_token_hash_key_id END
        FROM batch WHERE target.id = batch.id RETURNING 1
      ) SELECT count(*)::bigint AS count FROM updated`)[0].count);
  case "otp-network":
    return Number((await sql`
      WITH batch AS MATERIALIZED (
        SELECT id FROM otp_challenges
        WHERE network_hash IS NOT NULL AND network_key_id IS NULL
        ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${batchSize}
      ), updated AS (
        UPDATE otp_challenges target SET network_key_id = 'legacy-v1'
        FROM batch WHERE target.id = batch.id RETURNING 1
      ) SELECT count(*)::bigint AS count FROM updated`)[0].count);
  case "call-network":
    return Number((await sql`
      WITH batch AS MATERIALIZED (
        SELECT id FROM call_invite_attempts
        WHERE network_hash IS NOT NULL AND network_key_id IS NULL
        ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${batchSize}
      ), updated AS (
        UPDATE call_invite_attempts target SET network_key_id = 'legacy-v1'
        FROM batch WHERE target.id = batch.id RETURNING 1
      ) SELECT count(*)::bigint AS count FROM updated`)[0].count);
  case "message-preview-url":
    return Number((await sql`
      WITH batch AS MATERIALIZED (
        SELECT dialog_id, msg_id FROM message_link_previews
        WHERE url_lookup_hmac IS NOT NULL AND url_lookup_key_id IS NULL
        ORDER BY dialog_id, msg_id FOR UPDATE SKIP LOCKED LIMIT ${batchSize}
      ), updated AS (
        UPDATE message_link_previews target SET url_lookup_key_id = 'legacy-v1'
        FROM batch WHERE target.dialog_id = batch.dialog_id AND target.msg_id = batch.msg_id
        RETURNING 1
      ) SELECT count(*)::bigint AS count FROM updated`)[0].count);
  }
}

/**
 * Labels legacy hashes in bounded, resumable batches. New and old binaries that omit the added
 * column receive the legacy-v1 default, so this converges safely during a rolling deployment.
 */
export async function backfillBlindIndexKeyLabels(
  sql: SQL,
  domains: BlindIndexLabelBackfillDomain[],
  requestedBatchSize = 1_000,
): Promise<Record<BlindIndexLabelBackfillDomain, number>> {
  const result: Record<BlindIndexLabelBackfillDomain, number> = {
    devices: 0,
    "otp-network": 0,
    "call-network": 0,
    "message-preview-url": 0,
  };
  for (const domain of domains) {
    while (true) {
      const updated = await backfillDomainBatch(sql, domain, requestedBatchSize);
      if (!Number.isSafeInteger(updated) || updated < 0) {
        throw new Error(`invalid blind-index label backfill count for ${domain}`);
      }
      result[domain] += updated;
      if (updated === 0) break;
    }
  }
  return result;
}
