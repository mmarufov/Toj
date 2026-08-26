import type { SQL } from "bun";
import { blindIndexReadiness } from "./blind-index";
import { PHONE_AAD, phoneLookupIndex } from "./crypto";
import { openForScope, preloadEnvelopeKeys } from "./envelope-crypto";

/**
 * Phone identity is the only durable blind index whose source value is recoverable in bulk.
 * Opaque session/idempotency inputs use separate retention or migration policies; their old key
 * must remain configured until an exact blindIndexDatabaseReadiness audit reports zero references.
 */
export async function migratePhoneBlindIndexBatch(
  sql: SQL,
  requestedBatchSize = 100,
  fromKeyId = "legacy-v1",
): Promise<{ scanned: number; migrated: number; hasMore: boolean; activeKeyId: string; fromKeyId: string }> {
  const batchSize = Math.max(1, Math.min(1_000, requestedBatchSize));
  const activeKeyId = blindIndexReadiness().activeKeyId;
  if (activeKeyId === "legacy-v1") {
    throw new Error("configure a versioned active blind-index key before phone migration");
  }
  if (fromKeyId === activeKeyId) throw new Error("source and active blind-index keys must differ");
  return await sql.begin(async (tx) => {
    const rows = await tx`
      SELECT id, phone_lookup_hash, phone_lookup_key_id,
             phone_key_id, phone_nonce, phone_e164_ciphertext
      FROM accounts
      WHERE status <> 'deleted' AND phone_lookup_key_id = ${fromKeyId}
      ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${batchSize}`;
    await preloadEnvelopeKeys(tx, rows.map((row: any) => String(row.phone_key_id)));
    let migrated = 0;
    for (const row of rows) {
      const plaintext = await openForScope(tx, {
        kind: "account", accountId: String(row.id),
      }, {
        keyId: String(row.phone_key_id),
        nonce: Buffer.from(row.phone_nonce),
        ciphertext: Buffer.from(row.phone_e164_ciphertext),
      }, PHONE_AAD);
      try {
        const next = phoneLookupIndex(plaintext.toString("utf8"));
        const updated = await tx`
          UPDATE accounts SET phone_lookup_hash = ${next.digest},
            phone_lookup_key_id = ${next.keyId}, updated_at = now()
          WHERE id = ${row.id} AND phone_lookup_key_id = ${row.phone_lookup_key_id}
            AND phone_lookup_hash = ${row.phone_lookup_hash}
          RETURNING id`;
        migrated += updated.length;
      } finally {
        plaintext.fill(0);
      }
    }
    const hasMore = Boolean((await tx`
      SELECT EXISTS (
        SELECT 1 FROM accounts
        WHERE status <> 'deleted' AND phone_lookup_key_id = ${fromKeyId}
        LIMIT 1
      ) AS present`)[0].present);
    return { scanned: rows.length, migrated, hasMore, activeKeyId, fromKeyId };
  });
}
