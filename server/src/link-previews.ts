import type { SQL } from "bun";
import sharp from "sharp";
import {
  linkPreviewAssetAAD,
  linkPreviewAssetDigestIndex,
  linkPreviewLookupCandidates,
  linkPreviewLookupIndex,
  linkPreviewMetadataAAD,
  linkPreviewURLAAD,
} from "./crypto";
import { openForScope, preloadEnvelopeKeys, sealForScope } from "./envelope-crypto";
import { fanoutDialogEvent } from "./fanout";
import { fetchPublicResource, SafeHTTPError, validatePublicURL } from "./safe-http-client";
import { notifySyncWakeups } from "./sync-wakeup";
import { touchWorkerHeartbeat } from "./cloud-productivity-readiness";
import {
  adjustProductivityActiveJobs,
  linkPreviewWorkerConcurrency,
  productivityWorkerLeaseSeconds,
  recordProductivityLeaseRenewalFailure,
  recordResolvedPreviewWaiters,
} from "./productivity-runtime";

const MAX_HTML_BYTES = 1 * 1_024 * 1_024;
const MAX_IMAGE_BYTES = 5 * 1_024 * 1_024;
const MAX_PREVIEW_IMAGE_BYTES = 512 * 1_024;
const MAX_IMAGE_PIXELS = 20_000_000;
const MAX_FETCH_ATTEMPTS = 3;

export class LinkPreviewError extends Error {
  constructor(message: string, readonly code = "invalid_link_preview", readonly status = 400) {
    super(message);
    this.name = "LinkPreviewError";
  }
}

export type LinkPreviewCandidate = {
  url: string;
  utf16Offset: number;
  utf16Length: number;
  disabled: boolean;
};

export type LinkPreviewDTO = {
  state: "pending" | "ready" | "unavailable" | "disabled";
  originalUrl: string | null;
  finalUrl: string | null;
  destinationHost: string | null;
  title: string | null;
  description: string | null;
  siteName: string | null;
  assetId: string | null;
  fetchedAt: string | null;
};

type PreviewMetadata = {
  title: string;
  description: string | null;
  siteName: string | null;
  destinationHost: string;
};

type ClaimedPreview = { lookup: Buffer; leaseToken: string };

const n = (value: unknown) => Number(value as any);
const iso = (value: unknown): string => value instanceof Date ? value.toISOString() : String(value);

export function normalizeLinkPreviewCandidate(
  value: unknown,
  body: string,
): LinkPreviewCandidate | null {
  if (value == null) return null;
  const raw = value as any;
  const disabled = Boolean(raw.disabled);
  if (disabled) return { url: "", utf16Offset: 0, utf16Length: 0, disabled: true };
  const url = String(raw.url ?? "");
  const utf16Offset = Number(raw.utf16Offset ?? raw.utf16_offset);
  const utf16Length = Number(raw.utf16Length ?? raw.utf16_length);
  if (
    !Number.isSafeInteger(utf16Offset) || utf16Offset < 0
    || !Number.isSafeInteger(utf16Length) || utf16Length <= 0
    || utf16Offset + utf16Length > body.length
    || body.slice(utf16Offset, utf16Offset + utf16Length) !== url
  ) {
    return null;
  }
  try {
    const parsed = validatePublicURL(url);
    return {
      url: parsed.toString(),
      utf16Offset,
      utf16Length,
      disabled: false,
    };
  } catch {
    return null;
  }
}

/** Called inside the message transaction. It never performs remote I/O. */
export async function enqueueLinkPreview(
  sql: SQL,
  input: {
    accountId: string;
    dialogId: string;
    msgId: number;
    editVersion: number;
    body: string;
    candidate: unknown;
    generation?: number;
  },
): Promise<void> {
  const candidate = normalizeLinkPreviewCandidate(input.candidate, input.body);
  const generation = Math.max(1, input.generation ?? 1);
  await sql`
    DELETE FROM link_preview_waiters
    WHERE dialog_id = ${input.dialogId} AND msg_id = ${input.msgId}`;
  await sql`
    DELETE FROM message_link_previews
    WHERE dialog_id = ${input.dialogId} AND msg_id = ${input.msgId}`;
  if (!candidate) return;
  if (candidate.disabled) {
    await sql`
      INSERT INTO message_link_previews(
        dialog_id, msg_id, generation, expected_edit_version, state
      ) VALUES (
        ${input.dialogId}, ${input.msgId}, ${generation}, ${input.editVersion}, 'disabled'
      )`;
    return;
  }

  const lookupCandidates = linkPreviewLookupCandidates(candidate.url);
  const activeLookup = linkPreviewLookupIndex(candidate.url);
  const existing = (await sql`
    SELECT url_lookup_hmac, url_lookup_key_id, state, current_snapshot_id, expires_at
    FROM link_preview_cache_entries
    WHERE url_lookup_hmac IN (
      SELECT decode(value, 'hex') FROM unnest(
        ${sql.array(lookupCandidates.map((entry) => entry.digest.toString("hex")), "text")}::text[]
      ) candidate(value)
    )
    ORDER BY (url_lookup_key_id = ${activeLookup.keyId}) DESC, created_at DESC
    LIMIT 1 FOR UPDATE`)[0];
  const lookup = existing ? Buffer.from(existing.url_lookup_hmac) : activeLookup.digest;
  const lookupKeyId = existing ? String(existing.url_lookup_key_id) : activeLookup.keyId;
  let state: LinkPreviewDTO["state"] = "pending";
  let snapshotId: string | null = null;
  if (existing?.state === "ready" && existing.expires_at && new Date(existing.expires_at) > new Date()) {
    state = "ready";
    snapshotId = String(existing.current_snapshot_id);
  } else if (
    existing?.state === "negative"
    && existing.expires_at
    && new Date(existing.expires_at) > new Date()
  ) {
    state = "unavailable";
  } else {
    if (!existing) {
      const budget = await sql`
        INSERT INTO link_preview_action_budgets(account_id, bucket_started, accepted_count)
        VALUES (${input.accountId}, date_trunc('hour', now()), 1)
        ON CONFLICT (account_id, bucket_started) DO UPDATE SET
          accepted_count = link_preview_action_budgets.accepted_count + 1,
          updated_at = now()
        WHERE link_preview_action_budgets.accepted_count < 60
        RETURNING accepted_count`;
      if (!budget.length) state = "unavailable";
    }
    if (state === "pending") {
      const cacheURL = await sealForScope(
        sql,
        { kind: "service", serviceName: "link-preview" },
        candidate.url,
        linkPreviewURLAAD("cache", lookup.toString("hex")),
      );
      await sql`
        INSERT INTO link_preview_cache_entries(
          url_lookup_hmac, url_lookup_key_id, url_key_id, url_nonce, url_ciphertext,
          state, available_at
        ) VALUES (
          ${lookup}, ${lookupKeyId}, ${cacheURL.keyId}, ${cacheURL.nonce},
          ${cacheURL.ciphertext}, 'pending', now()
        )
        ON CONFLICT (url_lookup_hmac) DO UPDATE SET
          state = CASE
            WHEN link_preview_cache_entries.state = 'fetching'
              AND link_preview_cache_entries.lease_expires_at > now()
            THEN link_preview_cache_entries.state
            ELSE 'pending'
          END,
          available_at = CASE
            WHEN link_preview_cache_entries.state = 'fetching'
              AND link_preview_cache_entries.lease_expires_at > now()
            THEN link_preview_cache_entries.available_at
            ELSE now()
          END,
          expires_at = NULL,
          last_error_code = NULL,
          updated_at = now()`;
    }
  }

  const messageURL = await sealForScope(
    sql,
    { kind: "account", accountId: input.accountId },
    candidate.url,
    linkPreviewURLAAD("message", `${input.dialogId}:${input.msgId}:${generation}`),
  );
  await sql`
    INSERT INTO message_link_previews(
      dialog_id, msg_id, generation, expected_edit_version, url_lookup_hmac,
      url_lookup_key_id, original_url_key_id, original_url_nonce,
      original_url_ciphertext, state, snapshot_id
    ) VALUES (
      ${input.dialogId}, ${input.msgId}, ${generation}, ${input.editVersion},
      ${lookup}, ${lookupKeyId},
      ${messageURL.keyId}, ${messageURL.nonce}, ${messageURL.ciphertext}, ${state}, ${snapshotId}
    )`;
  if (state === "pending") {
    await sql`
      INSERT INTO link_preview_waiters(
        url_lookup_hmac, url_lookup_key_id, dialog_id, msg_id, expected_edit_version, generation
      ) VALUES (
        ${lookup}, ${lookupKeyId}, ${input.dialogId}, ${input.msgId},
        ${input.editVersion}, ${generation}
      )
      ON CONFLICT (url_lookup_hmac, dialog_id, msg_id) DO UPDATE SET
        expected_edit_version = excluded.expected_edit_version,
        generation = excluded.generation`;
  }
}

function decodeEntities(value: string): string {
  const named: Record<string, string> = {
    amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  };
  return value.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, entity: string) => {
    if (entity.startsWith("#x")) {
      const code = Number.parseInt(entity.slice(2), 16);
      return Number.isSafeInteger(code) ? String.fromCodePoint(code) : "";
    }
    if (entity.startsWith("#")) {
      const code = Number.parseInt(entity.slice(1), 10);
      return Number.isSafeInteger(code) ? String.fromCodePoint(code) : "";
    }
    return named[entity.toLowerCase()] ?? match;
  });
}

function cleanText(value: string | null | undefined, maxScalars: number): string | null {
  if (!value) return null;
  const normalized = decodeEntities(value)
    .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
  if (!normalized) return null;
  return [...normalized].slice(0, maxScalars).join("");
}

function attributes(fragment: string): Record<string, string> {
  const result: Record<string, string> = {};
  const regex = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g;
  for (const match of fragment.matchAll(regex)) {
    result[match[1].toLowerCase()] = match[2] ?? match[3] ?? match[4] ?? "";
  }
  return result;
}

function parseMetadata(html: string, finalURL: URL): {
  metadata: PreviewMetadata;
  imageURL: string | null;
} {
  const tags = new Map<string, string>();
  for (const match of html.matchAll(/<meta\s+([^>]{0,4096})>/gi)) {
    const attr = attributes(match[1]);
    const key = String(attr.property ?? attr.name ?? "").toLowerCase();
    if (key && attr.content != null && !tags.has(key)) tags.set(key, attr.content);
  }
  const robots = String(tags.get("robots") ?? "").toLowerCase();
  if (robots.split(/[\s,]+/).includes("nosnippet")) {
    throw new LinkPreviewError("origin disabled snippets", "origin_no_snippet");
  }
  const titleMatch = html.match(/<title(?:\s[^>]*)?>([\s\S]{0,2048}?)<\/title>/i);
  const title = cleanText(
    tags.get("og:title") ?? titleMatch?.[1] ?? tags.get("twitter:title") ?? finalURL.hostname,
    200,
  ) ?? finalURL.hostname;
  const description = cleanText(
    tags.get("og:description") ?? tags.get("description") ?? tags.get("twitter:description"),
    500,
  );
  const siteName = cleanText(tags.get("og:site_name"), 100);
  const image = tags.get("og:image") ?? tags.get("twitter:image") ?? null;
  let imageURL: string | null = null;
  if (image && !image.trim().toLowerCase().startsWith("data:")) {
    try {
      const parsed = validatePublicURL(new URL(image, finalURL).toString());
      if (!parsed.pathname.toLowerCase().endsWith(".svg")) imageURL = parsed.toString();
    } catch {
      imageURL = null;
    }
  }
  return {
    metadata: {
      title,
      description,
      siteName,
      destinationHost: finalURL.hostname.toLowerCase(),
    },
    imageURL,
  };
}

export function parseLinkPreviewMetadata(
  html: string,
  finalURL: URL,
): { title: string; description: string | null; siteName: string | null; imageURL: string | null } {
  const parsed = parseMetadata(html, finalURL);
  return {
    title: parsed.metadata.title,
    description: parsed.metadata.description,
    siteName: parsed.metadata.siteName,
    imageURL: parsed.imageURL,
  };
}

async function fetchImage(url: string | null, signal?: AbortSignal): Promise<Buffer | null> {
  if (!url) return null;
  try {
    const response = await fetchPublicResource(url, {
      maxBytes: MAX_IMAGE_BYTES,
      accept: "image/jpeg,image/png,image/webp,image/avif",
      signal,
    });
    if (response.status < 200 || response.status >= 300) return null;
    const type = String(response.headers["content-type"] ?? "").split(";", 1)[0].trim();
    if (!["image/jpeg", "image/png", "image/webp", "image/avif"].includes(type)) return null;
    const source = sharp(response.body, {
      limitInputPixels: MAX_IMAGE_PIXELS,
      failOn: "warning",
      sequentialRead: true,
    }).rotate().flatten({ background: "#ffffff" }).resize({
      width: 1_200,
      height: 630,
      fit: "inside",
      withoutEnlargement: true,
    });
    for (const quality of [82, 72, 62, 52, 42]) {
      const encoded = await source.clone().jpeg({ quality, progressive: false, mozjpeg: true }).toBuffer();
      if (encoded.length <= MAX_PREVIEW_IMAGE_BYTES) return encoded;
    }
    return null;
  } catch {
    return null;
  }
}

async function claimPreviewJobs(
  sql: SQL,
  limit: number,
  leaseSeconds: number,
): Promise<ClaimedPreview[]> {
  return await sql.begin(async (tx) => {
    const rows = await tx`
      WITH candidates AS (
        SELECT url_lookup_hmac
        FROM link_preview_cache_entries
        WHERE (
          state = 'pending' AND available_at <= now()
        ) OR (
          state = 'fetching' AND lease_expires_at <= now()
        )
        ORDER BY available_at, created_at
        LIMIT ${limit}
        FOR UPDATE SKIP LOCKED
      )
      UPDATE link_preview_cache_entries entry SET
        state = 'fetching', attempts = entry.attempts + 1, claimed_at = now(),
        lease_expires_at = now() + (${leaseSeconds}::text || ' seconds')::interval,
        lease_token = gen_random_uuid(),
        updated_at = now()
      FROM candidates
      WHERE entry.url_lookup_hmac = candidates.url_lookup_hmac
      RETURNING entry.url_lookup_hmac, entry.lease_token`;
    return rows.map((row: any) => ({
      lookup: Buffer.from(row.url_lookup_hmac),
      leaseToken: String(row.lease_token),
    }));
  });
}

async function renewPreviewLease(
  sql: SQL,
  claim: ClaimedPreview,
  leaseSeconds: number,
): Promise<boolean> {
  try {
    const rows = await sql`
      UPDATE link_preview_cache_entries
      SET lease_expires_at = now() + (${leaseSeconds}::text || ' seconds')::interval,
          updated_at = now()
      WHERE url_lookup_hmac = ${claim.lookup}
        AND state = 'fetching' AND lease_token = ${claim.leaseToken}
      RETURNING url_lookup_hmac`;
    return rows.length === 1;
  } catch {
    return false;
  }
}

async function publishPreview(
  sql: SQL,
  claim: ClaimedPreview,
  result: {
    originalURL: string;
    finalURL: string;
    metadata: PreviewMetadata;
    image: Buffer | null;
  },
): Promise<void> {
  const snapshotId = crypto.randomUUID();
  // Envelope sealing and image decoding are expensive, so they stay outside the write
  // transaction; the cache row is only locked for the inserts below.
  const scope = { kind: "service", serviceName: "link-preview" } as const;
  const sealedURL = await sealForScope(
    sql,
    scope,
    JSON.stringify({ originalURL: result.originalURL, finalURL: result.finalURL }),
    linkPreviewURLAAD("snapshot", snapshotId),
  );
  const sealedMetadata = await sealForScope(
    sql,
    scope,
    JSON.stringify(result.metadata),
    linkPreviewMetadataAAD(snapshotId),
  );
  const preparedAsset = result.image ? await (async () => {
    const id = crypto.randomUUID();
    const sealed = await sealForScope(sql, scope, result.image!, linkPreviewAssetAAD(id));
    const imageInfo = await sharp(result.image!).metadata();
    return {
      id,
      sealed,
      byteSize: result.image!.length,
      width: imageInfo.width ?? 1,
      height: imageInfo.height ?? 1,
      digest: linkPreviewAssetDigestIndex(result.image!),
    };
  })() : null;
  await sql.begin(async (tx) => {
    const cache = (await tx`
      SELECT 1 FROM link_preview_cache_entries
      WHERE url_lookup_hmac = ${claim.lookup}
        AND state = 'fetching' AND lease_token = ${claim.leaseToken}
      FOR UPDATE`)[0];
    if (!cache) return;
    const assetId = preparedAsset?.id ?? null;
    if (preparedAsset) {
      await tx`
        INSERT INTO link_preview_assets(
          id, key_id, nonce, ciphertext, content_type, byte_size, width, height,
          digest_hmac, digest_key_id
        ) VALUES (
          ${assetId}, ${preparedAsset.sealed.keyId}, ${preparedAsset.sealed.nonce},
          ${preparedAsset.sealed.ciphertext}, 'image/jpeg', ${preparedAsset.byteSize},
          ${preparedAsset.width}, ${preparedAsset.height},
          ${preparedAsset.digest.digest}, ${preparedAsset.digest.keyId}
        )`;
    }
    await tx`
      INSERT INTO link_preview_snapshots(
        id, url_key_id, url_nonce, url_ciphertext,
        metadata_key_id, metadata_nonce, metadata_ciphertext,
        asset_id, fetched_at, expires_at
      ) VALUES (
        ${snapshotId}, ${sealedURL.keyId}, ${sealedURL.nonce}, ${sealedURL.ciphertext},
        ${sealedMetadata.keyId}, ${sealedMetadata.nonce}, ${sealedMetadata.ciphertext},
        ${assetId}, now(), now() + interval '24 hours'
      )`;
    await tx`
      UPDATE link_preview_cache_entries SET
        state = 'ready', current_snapshot_id = ${snapshotId}, fetched_at = now(),
        expires_at = now() + interval '24 hours', claimed_at = NULL,
        lease_expires_at = NULL, lease_token = NULL, last_error_code = NULL,
        fanout_pending = EXISTS (
          SELECT 1 FROM link_preview_waiters waiter
          WHERE waiter.url_lookup_hmac = ${claim.lookup}
        ),
        updated_at = now()
      WHERE url_lookup_hmac = ${claim.lookup}
        AND state = 'fetching' AND lease_token = ${claim.leaseToken}`;
  });
}

async function publishUnavailable(
  sql: SQL,
  claim: ClaimedPreview,
  code: string,
): Promise<void> {
  await sql.begin(async (tx) => {
    const cache = (await tx`
      SELECT attempts FROM link_preview_cache_entries
      WHERE url_lookup_hmac = ${claim.lookup}
        AND state = 'fetching' AND lease_token = ${claim.leaseToken}
      FOR UPDATE`)[0];
    if (!cache) return;
    await tx`
      UPDATE link_preview_cache_entries SET
        state = 'negative', expires_at = now() + interval '1 hour', fetched_at = now(),
        claimed_at = NULL, lease_expires_at = NULL, lease_token = NULL,
        last_error_code = ${code},
        fanout_pending = EXISTS (
          SELECT 1 FROM link_preview_waiters waiter
          WHERE waiter.url_lookup_hmac = ${claim.lookup}
        ),
        updated_at = now()
      WHERE url_lookup_hmac = ${claim.lookup}
        AND state = 'fetching' AND lease_token = ${claim.leaseToken}`;
  });
}

async function drainOnePreviewFanoutTransaction(
  sql: SQL,
  batchSize: number,
): Promise<{ processed: number; found: boolean }> {
  return await sql.begin(async (tx) => {
    const cache = (await tx`
      SELECT url_lookup_hmac, state, current_snapshot_id
      FROM link_preview_cache_entries
      WHERE fanout_pending AND state IN ('ready','negative')
      ORDER BY updated_at, url_lookup_hmac
      LIMIT 1
      FOR UPDATE SKIP LOCKED`)[0];
    if (!cache) return { processed: 0, found: false };
    const lookup = Buffer.from(cache.url_lookup_hmac);
    const waiters = await tx`
      SELECT waiter.dialog_id, waiter.msg_id, waiter.expected_edit_version, waiter.generation,
             message.sender_account_id,
             (
               message.state = 'visible'
               AND (message.expires_at IS NULL OR message.expires_at > now())
               AND message.edit_version = waiter.expected_edit_version
               AND relation.state = 'pending'
               AND relation.expected_edit_version = waiter.expected_edit_version
               AND relation.generation = waiter.generation
               AND relation.url_lookup_hmac = waiter.url_lookup_hmac
             ) AS valid
      FROM link_preview_waiters waiter
      JOIN messages message
        ON message.dialog_id = waiter.dialog_id AND message.msg_id = waiter.msg_id
      JOIN message_link_previews relation
        ON relation.dialog_id = waiter.dialog_id AND relation.msg_id = waiter.msg_id
      WHERE waiter.url_lookup_hmac = ${lookup}
      ORDER BY waiter.dialog_id, waiter.msg_id
      LIMIT ${batchSize}
      FOR UPDATE OF waiter SKIP LOCKED`;
    const pushes = [];
    for (const waiter of waiters) {
      if (waiter.valid) {
        const updated = cache.state === "ready"
          ? await tx`
              UPDATE message_link_previews SET
                state = 'ready', snapshot_id = ${cache.current_snapshot_id}, updated_at = now()
              WHERE dialog_id = ${waiter.dialog_id} AND msg_id = ${waiter.msg_id}
                AND state = 'pending'
                AND generation = ${waiter.generation}
                AND expected_edit_version = ${waiter.expected_edit_version}
                AND url_lookup_hmac = ${lookup}
              RETURNING msg_id`
          : await tx`
              UPDATE message_link_previews SET
                state = 'unavailable', snapshot_id = NULL, updated_at = now()
              WHERE dialog_id = ${waiter.dialog_id} AND msg_id = ${waiter.msg_id}
                AND state = 'pending'
                AND generation = ${waiter.generation}
                AND expected_edit_version = ${waiter.expected_edit_version}
                AND url_lookup_hmac = ${lookup}
              RETURNING msg_id`;
        if (updated.length) {
          pushes.push(...await fanoutDialogEvent(tx, {
            dialogId: String(waiter.dialog_id),
            type: "message.preview_updated",
            msgId: n(waiter.msg_id),
            actorAccountId: String(waiter.sender_account_id),
            alertRecipients: false,
          }));
        }
      } else {
        // A message edit/delete/expiry may win after the waiter is selected. Remove only the
        // exact stale generation; a newer relation installed by a concurrent edit must survive.
        await tx`
          DELETE FROM message_link_previews
          WHERE dialog_id = ${waiter.dialog_id} AND msg_id = ${waiter.msg_id}
            AND state = 'pending'
            AND generation = ${waiter.generation}
            AND expected_edit_version = ${waiter.expected_edit_version}
            AND url_lookup_hmac = ${lookup}`;
      }
      await tx`
        DELETE FROM link_preview_waiters
        WHERE url_lookup_hmac = ${lookup}
          AND dialog_id = ${waiter.dialog_id} AND msg_id = ${waiter.msg_id}`;
    }
    const remaining = Boolean((await tx`
      SELECT EXISTS (
        SELECT 1 FROM link_preview_waiters WHERE url_lookup_hmac = ${lookup}
      ) AS present`)[0]?.present);
    await tx`
      UPDATE link_preview_cache_entries
      SET fanout_pending = ${remaining}, updated_at = now()
      WHERE url_lookup_hmac = ${lookup}`;
    await notifySyncWakeups(tx, pushes);
    return { processed: waiters.length, found: true };
  });
}

/** Processes no more than 25 waiter rows per transaction and 100 rows per worker tick. */
export async function drainLinkPreviewFanout(sql: SQL, maxRows = 100): Promise<number> {
  const boundedMax = Math.max(1, Math.min(100, Number(maxRows)));
  let processed = 0;
  let transactions = 0;
  while (processed < boundedMax && transactions < 100) {
    const result = await drainOnePreviewFanoutTransaction(
      sql,
      Math.min(25, boundedMax - processed),
    );
    transactions += 1;
    if (!result.found) break;
    // Another fanout worker may own every waiter for the selected cache row. Do not burn the rest
    // of this tick repeatedly selecting that row while SKIP LOCKED correctly returns no progress.
    if (result.processed === 0) break;
    processed += result.processed;
  }
  recordResolvedPreviewWaiters(processed);
  return processed;
}

async function returnPreviewForRetry(
  sql: SQL,
  claim: ClaimedPreview,
  attempts: number,
  code: string,
): Promise<void> {
  const delay = Math.min(300, 2 ** Math.min(8, attempts));
  await sql`
    UPDATE link_preview_cache_entries SET
      state = 'pending', available_at = now() + (${delay}::text || ' seconds')::interval,
      claimed_at = NULL, lease_expires_at = NULL, lease_token = NULL,
      last_error_code = ${code}, updated_at = now()
    WHERE url_lookup_hmac = ${claim.lookup}
      AND state = 'fetching' AND lease_token = ${claim.leaseToken}`;
}

async function processPreview(
  sql: SQL,
  claim: ClaimedPreview,
  signal?: AbortSignal,
): Promise<void> {
  const row = (await sql`
    SELECT url_key_id, url_nonce, url_ciphertext, attempts
    FROM link_preview_cache_entries
    WHERE url_lookup_hmac = ${claim.lookup}
      AND state = 'fetching' AND lease_token = ${claim.leaseToken}`)[0];
  if (!row) return;
  const originalURL = (await openForScope(
    sql,
    { kind: "service", serviceName: "link-preview" },
    {
      keyId: String(row.url_key_id),
      nonce: Buffer.from(row.url_nonce),
      ciphertext: Buffer.from(row.url_ciphertext),
    },
    linkPreviewURLAAD("cache", claim.lookup.toString("hex")),
  )).toString("utf8");
  try {
    const response = await fetchPublicResource(originalURL, {
      maxBytes: MAX_HTML_BYTES,
      accept: "text/html,application/xhtml+xml",
      signal,
    });
    if (response.status < 200 || response.status >= 300) {
      throw new SafeHTTPError("origin status is unavailable", "origin_status", response.status >= 500);
    }
    const contentType = String(response.headers["content-type"] ?? "").toLowerCase();
    if (!contentType.startsWith("text/html") && !contentType.startsWith("application/xhtml+xml")) {
      throw new SafeHTTPError("origin is not HTML", "not_html");
    }
    const html = response.body.toString("utf8");
    const { metadata, imageURL } = parseMetadata(html, response.url);
    const image = await fetchImage(imageURL, signal);
    if (signal?.aborted) {
      await returnPreviewForRetry(sql, claim, n(row.attempts), "worker_stopped");
      return;
    }
    await publishPreview(sql, claim, {
      originalURL,
      finalURL: response.url.toString(),
      metadata,
      image,
    });
  } catch (error) {
    const attempts = n(row.attempts);
    if (signal?.aborted) {
      await returnPreviewForRetry(sql, claim, attempts, "worker_stopped");
    } else if (error instanceof SafeHTTPError && error.transient && attempts < MAX_FETCH_ATTEMPTS) {
      await returnPreviewForRetry(sql, claim, attempts, error.code);
    } else {
      await publishUnavailable(
        sql,
        claim,
        error instanceof SafeHTTPError || error instanceof LinkPreviewError
          ? error.code
          : "preview_parse_failed",
      );
    }
  }
}

export async function drainLinkPreviews(
  sql: SQL,
  limit = linkPreviewWorkerConcurrency(),
  options: {
    concurrency?: number;
    leaseSeconds?: number;
    renewEveryMilliseconds?: number;
    controllers?: Set<AbortController>;
  } = {},
): Promise<number> {
  const concurrency = Math.max(1, Math.min(16, options.concurrency ?? linkPreviewWorkerConcurrency()));
  const leaseSeconds = Math.max(30, Math.min(600, options.leaseSeconds ?? productivityWorkerLeaseSeconds()));
  const renewEveryMilliseconds = Math.max(1_000, Math.min(
    30_000,
    Math.floor(leaseSeconds * 1_000 / 3),
    options.renewEveryMilliseconds ?? 30_000,
  ));
  const claims = await claimPreviewJobs(sql, Math.max(1, Math.min(concurrency, limit)), leaseSeconds);
  await Promise.all(claims.map(async (claim) => {
    const controller = new AbortController();
    options.controllers?.add(controller);
    let finished = false;
    let renewalRunning = false;
    const renew = async () => {
      if (finished || renewalRunning) return;
      renewalRunning = true;
      const owned = await renewPreviewLease(sql, claim, leaseSeconds);
      renewalRunning = false;
      if (!owned && !finished) recordProductivityLeaseRenewalFailure("link_preview");
    };
    const renewalTimer = setInterval(() => void renew(), renewEveryMilliseconds);
    renewalTimer.unref?.();
    adjustProductivityActiveJobs("link_preview", 1);
    try {
      await processPreview(sql, claim, controller.signal);
    } finally {
      finished = true;
      clearInterval(renewalTimer);
      options.controllers?.delete(controller);
      adjustProductivityActiveJobs("link_preview", -1);
    }
  }));
  return claims.length;
}

export function startLinkPreviewWorker(
  sql: SQL,
  options: {
    pollMilliseconds?: number;
    workerId?: string;
    concurrency?: number;
    leaseSeconds?: number;
    renewEveryMilliseconds?: number;
    heartbeatMilliseconds?: number;
    shutdownDrainMilliseconds?: number;
  } = {},
): () => Promise<void> {
  const workerId = options.workerId ?? crypto.randomUUID();
  const pollMilliseconds = Math.max(500, options.pollMilliseconds ?? 2_000);
  const concurrency = Math.max(1, Math.min(16, options.concurrency ?? linkPreviewWorkerConcurrency()));
  const leaseSeconds = Math.max(30, Math.min(600, options.leaseSeconds ?? productivityWorkerLeaseSeconds()));
  const heartbeatMilliseconds = Math.max(1_000, options.heartbeatMilliseconds ?? 10_000);
  const shutdownDrainMilliseconds = Math.max(1_000, options.shutdownDrainMilliseconds ?? 15_000);
  let running: Promise<void> | null = null;
  let stopped = false;
  let heartbeatRunning = false;
  const controllers = new Set<AbortController>();
  const tick = async () => {
    if (running || stopped) return;
    const work = (async () => {
      try {
        await drainLinkPreviewFanout(sql, 100);
        if (!stopped) await drainLinkPreviews(sql, concurrency, {
          concurrency,
          leaseSeconds,
          renewEveryMilliseconds: options.renewEveryMilliseconds,
          controllers,
        });
      } catch {
        // Queue depth and heartbeat age carry operational state without logging URLs or hostnames.
      }
    })();
    running = work;
    await work.finally(() => {
      if (running === work) running = null;
    });
  };
  const heartbeat = async () => {
    if (stopped || heartbeatRunning) return;
    heartbeatRunning = true;
    try {
      await touchWorkerHeartbeat(sql, "link_preview", workerId);
    } catch {
      // The cached heartbeat snapshot fails closed; this timer keeps retrying independently.
    } finally {
      heartbeatRunning = false;
    }
  };
  void heartbeat();
  void tick();
  const timer = setInterval(() => void tick(), pollMilliseconds);
  const heartbeatTimer = setInterval(() => void heartbeat(), heartbeatMilliseconds);
  timer.unref?.();
  heartbeatTimer.unref?.();
  return async () => {
    stopped = true;
    clearInterval(timer);
    clearInterval(heartbeatTimer);
    for (const controller of controllers) controller.abort();
    const active = running;
    if (!active) return;
    await Promise.race([
      active,
      new Promise<void>((resolve) => {
        const drainTimer = setTimeout(resolve, shutdownDrainMilliseconds);
        drainTimer.unref?.();
      }),
    ]);
  };
}

export async function loadLinkPreviews(
  sql: SQL,
  keys: Array<{ dialogId: string; msgId: number }>,
): Promise<Map<string, LinkPreviewDTO>> {
  if (keys.length === 0) return new Map();
  const rows = await sql`
    WITH wanted AS (
      SELECT * FROM unnest(
        ${sql.array(keys.map((key) => key.dialogId), "uuid")}::uuid[],
        ${sql.array(keys.map((key) => key.msgId), "int8")}::bigint[]
      ) key(dialog_id, msg_id)
    )
    SELECT relation.dialog_id, relation.msg_id, relation.generation, relation.state,
           message.sender_account_id,
           relation.original_url_key_id, relation.original_url_nonce,
           relation.original_url_ciphertext, relation.snapshot_id,
           snapshot.url_key_id AS snapshot_url_key_id,
           snapshot.url_nonce AS snapshot_url_nonce,
           snapshot.url_ciphertext AS snapshot_url_ciphertext,
           snapshot.metadata_key_id, snapshot.metadata_nonce, snapshot.metadata_ciphertext,
           snapshot.asset_id, snapshot.fetched_at
    FROM wanted
    JOIN message_link_previews relation
      ON relation.dialog_id = wanted.dialog_id AND relation.msg_id = wanted.msg_id
    JOIN messages message
      ON message.dialog_id = relation.dialog_id AND message.msg_id = relation.msg_id
    LEFT JOIN link_preview_snapshots snapshot ON snapshot.id = relation.snapshot_id`;
  await preloadEnvelopeKeys(sql, rows.flatMap((row: any) => [
    row.original_url_key_id,
    row.snapshot_url_key_id,
    row.metadata_key_id,
  ]).filter(Boolean).map(String));
  const result = new Map<string, LinkPreviewDTO>();
  for (const row of rows) {
    const dialogId = String(row.dialog_id);
    const msgId = n(row.msg_id);
    const state = String(row.state) as LinkPreviewDTO["state"];
    let originalUrl: string | null = null;
    if (row.original_url_key_id) {
      originalUrl = (await openForScope(
        sql,
        { kind: "account", accountId: String(row.sender_account_id) },
        {
          keyId: String(row.original_url_key_id),
          nonce: Buffer.from(row.original_url_nonce),
          ciphertext: Buffer.from(row.original_url_ciphertext),
        },
        linkPreviewURLAAD("message", `${dialogId}:${msgId}:${n(row.generation)}`),
      )).toString("utf8");
    }
    let finalUrl: string | null = null;
    let metadata: PreviewMetadata | null = null;
    if (state === "ready" && row.snapshot_id) {
      const urls = JSON.parse((await openForScope(
        sql,
        { kind: "service", serviceName: "link-preview" },
        {
          keyId: String(row.snapshot_url_key_id),
          nonce: Buffer.from(row.snapshot_url_nonce),
          ciphertext: Buffer.from(row.snapshot_url_ciphertext),
        },
        linkPreviewURLAAD("snapshot", String(row.snapshot_id)),
      )).toString("utf8"));
      finalUrl = String(urls.finalURL);
      metadata = JSON.parse((await openForScope(
        sql,
        { kind: "service", serviceName: "link-preview" },
        {
          keyId: String(row.metadata_key_id),
          nonce: Buffer.from(row.metadata_nonce),
          ciphertext: Buffer.from(row.metadata_ciphertext),
        },
        linkPreviewMetadataAAD(String(row.snapshot_id)),
      )).toString("utf8"));
    }
    result.set(`${dialogId}:${msgId}`, {
      state,
      originalUrl,
      finalUrl,
      destinationHost: metadata?.destinationHost ?? (() => {
        try { return originalUrl ? new URL(originalUrl).hostname.toLowerCase() : null; } catch { return null; }
      })(),
      title: metadata?.title ?? null,
      description: metadata?.description ?? null,
      siteName: metadata?.siteName ?? null,
      assetId: row.asset_id == null ? null : String(row.asset_id),
      fetchedAt: row.fetched_at == null ? null : iso(row.fetched_at),
    });
  }
  return result;
}

export async function downloadLinkPreviewAsset(
  sql: SQL,
  accountId: string,
  assetId: string,
): Promise<{ bytes: Buffer; contentType: string }> {
  const row = (await sql`
    SELECT asset.key_id, asset.nonce, asset.ciphertext, asset.content_type
    FROM link_preview_assets asset
    WHERE asset.id = ${assetId}
      AND EXISTS (
        SELECT 1
        FROM link_preview_snapshots snapshot
        JOIN message_link_previews relation ON relation.snapshot_id = snapshot.id
        JOIN messages message
          ON message.dialog_id = relation.dialog_id AND message.msg_id = relation.msg_id
        JOIN dialog_members member ON member.dialog_id = relation.dialog_id
        JOIN dialogs dialog ON dialog.id = relation.dialog_id
        WHERE snapshot.asset_id = asset.id
          AND EXISTS (
            SELECT 1 FROM messages message
            WHERE message.dialog_id = relation.dialog_id
              AND message.msg_id = relation.msg_id
              AND message.state = 'visible'
          )
          AND member.account_id = ${accountId}
          AND message.state = 'visible'
          AND (message.expires_at IS NULL OR message.expires_at > now())
          AND member.left_at IS NULL
          AND dialog.closed_at IS NULL
          AND (
            dialog.type <> 'saved'
            OR (dialog.created_by = ${accountId} AND member.role = 'owner')
          )
      )`)[0];
  if (!row) throw new LinkPreviewError("preview asset not found", "preview_asset_not_found", 404);
  return {
    bytes: await openForScope(
      sql,
      { kind: "service", serviceName: "link-preview" },
      {
        keyId: String(row.key_id),
        nonce: Buffer.from(row.nonce),
        ciphertext: Buffer.from(row.ciphertext),
      },
      linkPreviewAssetAAD(assetId),
    ),
    contentType: String(row.content_type),
  };
}
