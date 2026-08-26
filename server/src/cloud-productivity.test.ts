import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import {
  ChatFolderError,
  createChatFolder,
  getChatFolders,
  updateChatFolder,
} from "./chat-folders";
import { makeSql } from "./db";
import { startCloudServer } from "./cloud";
import { isPublicAddress, validatePublicURL } from "./safe-http-client";
import { parseLinkPreviewMetadata } from "./link-previews";
import {
  cancelScheduledDelivery,
  createScheduledDelivery,
  drainScheduledDeliveries,
  failScheduledDeliveriesForRevokedDialogInTransaction,
  listScheduledDeliveries,
  updateScheduledDelivery,
} from "./scheduled-deliveries";
import { editMessage, getDifference, getOrCreateDirectDialog, sendMessage } from "./sync";
import { linkPreviewLookupCandidates } from "./crypto";
import { cloudProductivitySchemaState } from "./cloud-productivity-readiness";

// Worker behavior is exercised deterministically through drain functions below. Background loops
// from HTTP-route tests would otherwise race assertions against the shared integration database.
process.env.TOJ_PRODUCTIVITY_WORKERS_DISABLED = "1";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  delete process.env.TOJ_BLIND_INDEX_KEYRING;
  delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
  // The URL cache is service-owned rather than account-owned, so account CASCADE cleanup cannot
  // remove key-rotation fixtures. Clear it explicitly to keep later readiness processes honest.
  await db`TRUNCATE link_preview_cache_entries, accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

afterAll(async () => {
  await resetDb();
  await db.close();
});

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function directPair() {
  const alice = await account("+16505554101", "Alice");
  const bob = await account("+16505554102", "Bob");
  const dialog = await getOrCreateDirectDialog(
    db, alice.accountId, bob.accountId, alice.deviceId,
  );
  return { alice, bob, dialogId: dialog.dialogId };
}

describe("cloud productivity features", () => {
  beforeEach(resetDb);

  test("schema readiness rejects a prior v1 encryption shape", async () => {
    expect((await cloudProductivitySchemaState(db, { bypassCache: true })).ready).toBe(true);
    let incomplete: Awaited<ReturnType<typeof cloudProductivitySchemaState>> | null = null;
    try {
      await db.begin(async (tx) => {
        await tx`ALTER TABLE link_preview_assets DROP COLUMN digest_key_id`;
        incomplete = await cloudProductivitySchemaState(tx, { bypassCache: true });
        throw new Error("rollback readiness fixture");
      });
    } catch (error) {
      expect(String(error)).toContain("rollback readiness fixture");
    }
    expect(incomplete?.ready).toBe(false);
    expect(incomplete?.missingColumns).toContain("link_preview_assets.digest_key_id");
  });

  test("chat folders are encrypted, idempotent, revision checked, and sync as snapshots", async () => {
    const { alice, dialogId } = await directPair();
    const before = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0].pts);
    const folderId = crypto.randomUUID();
    const mutationId = crypto.randomUUID();
    const body = {
      folderId,
      clientMutationId: mutationId,
      title: "Family",
      icon: "family",
      includeDirect: true,
      includeGroups: false,
      includeSaved: false,
      excludeRead: false,
      excludeMuted: false,
      excludeArchived: true,
      rules: [{ dialogId, rule: "include" }],
    };
    const created = await createChatFolder(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, body,
    });
    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "receipt-v2": Buffer.alloc(32, 0x66).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "receipt-v2";
    const duplicate = await createChatFolder(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, body,
    });
    expect(created.folders[0].title).toBe("Family");
    expect(duplicate.duplicate).toBe(true);
    const stored = (await db`
      SELECT title_key_id, title_ciphertext FROM chat_folders
      WHERE account_id = ${alice.accountId} AND folder_id = ${folderId}`)[0];
    expect(Buffer.from(stored.title_ciphertext).includes(Buffer.from("Family"))).toBe(false);
    if (process.env.TOJ_CRYPTO_MODE === "envelope"
      || (process.env.TOJ_CRYPTO_MODE === "envelope-canary"
        && process.env.TOJ_ENVELOPE_CANARY_PERCENT === "100")) {
      expect(stored.title_key_id).not.toBe("dev-v1");
    }

    await expect(updateChatFolder(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      folderId,
      body: { ...body, clientMutationId: crypto.randomUUID(), expectedRevision: 999 },
    })).rejects.toBeInstanceOf(ChatFolderError);

    const difference = await getDifference(db, alice.accountId, before, {
      chatFoldersEnabled: true,
    });
    if (difference.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(difference.updates.at(-1).chat_folders.folders[0].title).toBe("Family");
    expect((await getChatFolders(db, alice.accountId)).collectionRevision).toBe(1);
  });

  test("server dispatch survives client disappearance and is exactly once across worker retries", async () => {
    const { alice, bob, dialogId } = await directPair();
    const scheduleId = crypto.randomUUID();
    const requestBody = {
      scheduleId,
      clientMutationId: crypto.randomUUID(),
      dialogId,
      deliverAt: new Date(Date.now() + 61_000).toISOString(),
      items: [{ clientMsgId: crypto.randomUUID(), kind: "text", body: "from server" }],
    };
    const created = await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: requestBody,
    });
    expect(created.scheduledDelivery.state).toBe("scheduled");
    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "schedule-v2": Buffer.alloc(32, 0x68).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "schedule-v2";
    expect((await createScheduledDelivery(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, body: requestBody,
    })).duplicate).toBe(true);
    if (process.env.TOJ_CRYPTO_MODE === "envelope"
      || (process.env.TOJ_CRYPTO_MODE === "envelope-canary"
        && process.env.TOJ_ENVELOPE_CANARY_PERCENT === "100")) {
      expect((await db`SELECT payload_key_id FROM scheduled_delivery_items
        WHERE delivery_id = ${scheduleId}`)[0].payload_key_id).not.toBe("dev-v1");
    }
    // No client process participates after creation. Move the test clock by making the row due.
    await db`
      UPDATE scheduled_deliveries SET deliver_at = now(), available_at = now()
      WHERE id = ${scheduleId}`;
    expect(await drainScheduledDeliveries(db)).toBe(1);
    expect(await drainScheduledDeliveries(db)).toBe(0);
    const count = Number((await db`
      SELECT count(*) AS count FROM messages
      WHERE dialog_id = ${dialogId} AND body_ciphertext IS NOT NULL`)[0].count);
    expect(count).toBe(1);
    const state = (await listScheduledDeliveries(db, alice.accountId)).deliveries[0];
    expect(state.state).toBe("delivered");
    expect(state.items).toEqual([]);
    const bobState = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${bob.accountId}`)[0].pts);
    expect(bobState).toBeGreaterThan(0);
  });

  test("cancel is final before a worker claim and cannot produce a message", async () => {
    const { alice, dialogId } = await directPair();
    const scheduleId = crypto.randomUUID();
    const created = await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: {
        scheduleId,
        clientMutationId: crypto.randomUUID(),
        dialogId,
        deliverAt: new Date(Date.now() + 61_000).toISOString(),
        items: [{ clientMsgId: crypto.randomUUID(), kind: "text", body: "cancel me" }],
      },
    });
    await cancelScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      deliveryId: scheduleId,
      body: {
        clientMutationId: crypto.randomUUID(),
        expectedRevision: created.scheduledDelivery.revision,
      },
    });
    await db`
      UPDATE scheduled_deliveries SET deliver_at = now(), available_at = now()
      WHERE id = ${scheduleId}`;
    expect(await drainScheduledDeliveries(db)).toBe(0);
    expect(Number((await db`
      SELECT count(*) AS count FROM messages WHERE dialog_id = ${dialogId}`)[0].count)).toBe(0);
  });

  test("stale worker health keeps scheduled reads, sync, and cancellation available", async () => {
    const previousEnabled = process.env.TOJ_SCHEDULED_DELIVERY_V1_ENABLED;
    const previousRollout = process.env.TOJ_SCHEDULED_DELIVERY_ROLLOUT_PERCENT;
    const previousMetricsToken = process.env.TOJ_METRICS_TOKEN;
    process.env.TOJ_SCHEDULED_DELIVERY_V1_ENABLED = "1";
    process.env.TOJ_SCHEDULED_DELIVERY_ROLLOUT_PERCENT = "100";
    process.env.TOJ_METRICS_TOKEN = "scheduled-outage-test";
    const { alice, dialogId } = await directPair();
    const scheduleId = crypto.randomUUID();
    const createRequest = {
      scheduleId,
      clientMutationId: crypto.randomUUID(),
      dialogId,
      deliverAt: new Date(Date.now() + 61_000).toISOString(),
      items: [{ clientMsgId: crypto.randomUUID(), kind: "text", body: "manageable" }],
    };
    const created = await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: createRequest,
    });
    await db`
      UPDATE scheduled_delivery_mutation_requests SET request_fingerprint = NULL
      WHERE account_id = ${alice.accountId}
        AND client_mutation_id = ${createRequest.clientMutationId}`;
    expect((await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: createRequest,
    })).duplicate).toBe(true);
    const rescheduleRequest = {
      clientMutationId: crypto.randomUUID(),
      expectedRevision: created.scheduledDelivery.revision,
      deliverAt: new Date(Date.now() + 121_000).toISOString(),
    };
    const rescheduled = await updateScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      deliveryId: scheduleId,
      operation: "reschedule",
      body: rescheduleRequest,
    });
    const updateRequest = {
      clientMutationId: crypto.randomUUID(),
      expectedRevision: rescheduled.scheduledDelivery.revision,
      silent: true,
    };
    const updated = await updateScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      deliveryId: scheduleId,
      body: updateRequest,
    });
    await db`DELETE FROM worker_heartbeats WHERE worker_kind = 'scheduled_delivery'`;
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    const base = `http://127.0.0.1:${server.port}`;
    const headers = {
      authorization: `Bearer ${alice.token}`,
      "content-type": "application/json",
    };
    try {
      const capabilities = await (await fetch(`${base}/v1/capabilities`, { headers })).json() as {
        capabilities: string[];
      };
      // A stale worker closes new-product discovery, but existing scheduled state remains
      // readable/cancelable below so rollback and outage recovery cannot strand user data.
      expect(capabilities.capabilities).not.toContain("scheduled_delivery_v1");

      const listed = await fetch(`${base}/v1/scheduled-messages?limit=100`, { headers });
      expect(listed.status).toBe(200);
      expect((await listed.json() as any).deliveries[0].id).toBe(scheduleId);

      const detail = await fetch(`${base}/v1/scheduled-messages/${scheduleId}`, { headers });
      expect(detail.status).toBe(200);
      expect((await detail.json() as any).scheduledDelivery.revision)
        .toBe(updated.scheduledDelivery.revision);

      const recoveredCreate = await fetch(`${base}/v1/scheduled-messages`, {
        method: "POST", headers, body: JSON.stringify(createRequest),
      });
      expect(recoveredCreate.status).toBe(200);
      expect((await recoveredCreate.json() as any).duplicate).toBe(true);

      const recoveredReschedule = await fetch(
        `${base}/v1/scheduled-messages/${scheduleId}/reschedule`,
        { method: "POST", headers, body: JSON.stringify(rescheduleRequest) },
      );
      expect(recoveredReschedule.status).toBe(200);
      expect((await recoveredReschedule.json() as any).duplicate).toBe(true);
      const changedReschedule = await fetch(
        `${base}/v1/scheduled-messages/${scheduleId}/reschedule`,
        {
          method: "POST",
          headers,
          body: JSON.stringify({
            ...rescheduleRequest,
            deliverAt: new Date(Date.now() + 181_000).toISOString(),
          }),
        },
      );
      expect(changedReschedule.status).toBe(409);
      expect((await changedReschedule.json() as any).code).toBe("idempotency_conflict");

      const recoveredUpdate = await fetch(`${base}/v1/scheduled-messages/${scheduleId}`, {
        method: "PATCH", headers, body: JSON.stringify(updateRequest),
      });
      expect(recoveredUpdate.status).toBe(200);
      expect((await recoveredUpdate.json() as any).duplicate).toBe(true);
      const changedUpdate = await fetch(`${base}/v1/scheduled-messages/${scheduleId}`, {
        method: "PATCH", headers, body: JSON.stringify({ ...updateRequest, silent: false }),
      });
      expect(changedUpdate.status).toBe(409);
      expect((await changedUpdate.json() as any).code).toBe("idempotency_conflict");

      const createResponse = await fetch(`${base}/v1/scheduled-messages`, {
        method: "POST", headers, body: "{}",
      });
      expect(createResponse.status).toBe(503);
      expect(createResponse.headers.get("retry-after")).toBe("15");
      expect((await createResponse.json() as any).code).toBe("scheduled_worker_unavailable");

      const rescheduleResponse = await fetch(
        `${base}/v1/scheduled-messages/${scheduleId}/reschedule`,
        { method: "POST", headers, body: "{}" },
      );
      expect(rescheduleResponse.status).toBe(503);
      expect((await rescheduleResponse.json() as any).code).toBe("scheduled_worker_unavailable");

      const difference = await fetch(`${base}/v1/sync/difference`, {
        method: "POST", headers, body: JSON.stringify({ sincePts: 0 }),
      });
      expect(difference.status).toBe(200);
      const updates = (await difference.json() as any).updates as any[];
      expect(updates.some((update) => update.type === "scheduled.created")).toBe(true);
      expect(updates.some((update) => update.type === "capability.skipped")).toBe(false);

      const canceled = await fetch(`${base}/v1/scheduled-messages/${scheduleId}`, {
        method: "DELETE",
        headers,
        body: JSON.stringify({
          clientMutationId: crypto.randomUUID(),
          expectedRevision: updated.scheduledDelivery.revision,
        }),
      });
      expect(canceled.status).toBe(200);
      expect((await canceled.json() as any).scheduledDelivery.state).toBe("canceled");

      const metricText = await (await fetch(`${base}/metrics`, {
        headers: { authorization: "Bearer scheduled-outage-test" },
      })).text();
      expect(metricText).toContain("toj_scheduled_worker_unavailable_total 2");
      expect(metricText)
        .toContain("toj_scheduled_cancellations_during_worker_outage_total 1");

      process.env.TOJ_SCHEDULED_DELIVERY_V1_ENABLED = "0";
      const disabled = await fetch(`${base}/v1/scheduled-messages?limit=100`, { headers });
      expect(disabled.status).toBe(404);
      process.env.TOJ_SCHEDULED_DELIVERY_V1_ENABLED = "1";
    } finally {
      server.stop(true);
      if (previousEnabled == null) delete process.env.TOJ_SCHEDULED_DELIVERY_V1_ENABLED;
      else process.env.TOJ_SCHEDULED_DELIVERY_V1_ENABLED = previousEnabled;
      if (previousRollout == null) delete process.env.TOJ_SCHEDULED_DELIVERY_ROLLOUT_PERCENT;
      else process.env.TOJ_SCHEDULED_DELIVERY_ROLLOUT_PERCENT = previousRollout;
      if (previousMetricsToken == null) delete process.env.TOJ_METRICS_TOKEN;
      else process.env.TOJ_METRICS_TOKEN = previousMetricsToken;
    }
  });

  test("dialog revocation immediately fails schedules and erases encrypted payloads", async () => {
    const { alice, dialogId } = await directPair();
    const scheduleId = crypto.randomUUID();
    await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: {
        scheduleId,
        clientMutationId: crypto.randomUUID(),
        dialogId,
        deliverAt: new Date(Date.now() + 61_000).toISOString(),
        items: [{ clientMsgId: crypto.randomUUID(), kind: "text", body: "erase me" }],
      },
    });
    await db.begin(async (tx) => {
      await failScheduledDeliveriesForRevokedDialogInTransaction(
        tx, alice.accountId, dialogId,
      );
    });
    expect((await db`
      SELECT state, last_error_code FROM scheduled_deliveries WHERE id = ${scheduleId}`)[0])
      .toMatchObject({ state: "failed", last_error_code: "access_revoked" });
    expect((await db`
      SELECT payload_key_id, payload_nonce, payload_ciphertext, media_id
      FROM scheduled_delivery_items WHERE delivery_id = ${scheduleId}`)[0])
      .toEqual(expect.objectContaining({
        payload_key_id: null, payload_nonce: null, payload_ciphertext: null, media_id: null,
      }));
  });

  test("an expired post-send lease replays through message idempotency without duplication", async () => {
    const { alice, dialogId } = await directPair();
    const scheduleId = crypto.randomUUID();
    const clientMsgId = crypto.randomUUID();
    await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: {
        scheduleId,
        clientMutationId: crypto.randomUUID(),
        dialogId,
        deliverAt: new Date(Date.now() + 61_000).toISOString(),
        items: [{ clientMsgId, kind: "text", body: "once" }],
      },
    });
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: null,
      dialogId,
      clientMsgId,
      body: "once",
      scheduledDeliveryId: scheduleId,
    });
    await db`
      UPDATE scheduled_deliveries SET state = 'processing', deliver_at = now(),
        available_at = now(), claimed_at = now() - interval '2 seconds',
        lease_token = gen_random_uuid(),
        lease_expires_at = now() - interval '1 second'
      WHERE id = ${scheduleId}`;
    expect(await drainScheduledDeliveries(db)).toBe(1);
    expect(Number((await db`
      SELECT count(*) AS count FROM messages WHERE dialog_id = ${dialogId}`)[0].count)).toBe(1);
    expect((await listScheduledDeliveries(db, alice.accountId)).deliveries[0].state).toBe("delivered");
  });

  test("preview fetch policy rejects private, loopback, mapped, credentialed, and nonstandard targets", () => {
    for (const address of ["127.0.0.1", "::1", "10.0.0.1", "169.254.169.254", "::ffff:127.0.0.1"]) {
      expect(isPublicAddress(address)).toBe(false);
    }
    expect(() => validatePublicURL("http://127.0.0.1/private")).toThrow();
    expect(() => validatePublicURL("https://user:pass@example.com/")).toThrow();
    expect(() => validatePublicURL("https://example.com:8443/")).toThrow();
    expect(validatePublicURL("https://example.com/path").hostname).toBe("example.com");
  });

  test("metadata parsing prefers Open Graph, sanitizes hostile controls, and honors nosnippet", () => {
    const parsed = parseLinkPreviewMetadata(`
      <html><head>
        <title>Fallback title</title>
        <meta property="og:title" content="Open &amp; Graph\u202e">
        <meta property="og:description" content="  Useful   summary  ">
        <meta property="og:site_name" content="Example">
        <meta property="og:image" content="/card.jpg">
      </head></html>
    `, new URL("https://example.com/article"));
    expect(parsed).toEqual({
      title: "Open & Graph",
      description: "Useful summary",
      siteName: "Example",
      imageURL: "https://example.com/card.jpg",
    });
    expect(() => parseLinkPreviewMetadata(
      '<meta name="robots" content="noindex,nosnippet"><title>Private</title>',
      new URL("https://example.com/"),
    )).toThrow("origin disabled snippets");
  });

  test("editing away a pending URL removes its waiter so stale metadata cannot attach", async () => {
    const { alice, dialogId } = await directPair();
    const url = `https://example.com/story/${crypto.randomUUID()}`;
    const body = `Read ${url}`;
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body,
      linkPreviewsEnabled: true,
      linkPreviewCandidate: {
        url,
        utf16Offset: 5,
        utf16Length: url.length,
        disabled: false,
      },
    });
    expect(Number((await db`
      SELECT count(*) AS count FROM link_preview_waiters
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0].count)).toBe(1);
    if (process.env.TOJ_CRYPTO_MODE === "envelope"
      || (process.env.TOJ_CRYPTO_MODE === "envelope-canary"
        && process.env.TOJ_ENVELOPE_CANARY_PERCENT === "100")) {
      const stored = (await db`
        SELECT relation.original_url_key_id, cache.url_key_id
        FROM message_link_previews relation
        JOIN link_preview_cache_entries cache
          ON cache.url_lookup_hmac = relation.url_lookup_hmac
        WHERE relation.dialog_id = ${dialogId} AND relation.msg_id = ${sent.msgId}`)[0];
      expect(stored.original_url_key_id).not.toBe("dev-v1");
      expect(stored.url_key_id).not.toBe("dev-v1");
    }
    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "preview-v2": Buffer.alloc(32, 0x67).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "preview-v2";
    await editMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      body,
      expectedEditVersion: 0,
      linkPreviewsEnabled: true,
      linkPreviewCandidate: {
        url, utf16Offset: 5, utf16Length: url.length, disabled: false,
      },
    });
    const candidateDigests = linkPreviewLookupCandidates(url).map((entry) => entry.digest.toString("hex"));
    expect(Number((await db`
      SELECT count(*) AS count FROM link_preview_cache_entries cache
      WHERE cache.url_lookup_hmac IN (
        SELECT decode(value, 'hex') FROM unnest(
          ${db.array(candidateDigests, "text")}::text[]
        ) candidate(value)
      )`)[0].count)).toBe(1);
    await editMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      body: "No link now",
      expectedEditVersion: 1,
      linkPreviewsEnabled: true,
      linkPreviewCandidate: null,
    });
    expect(Number((await db`
      SELECT count(*) AS count FROM link_preview_waiters
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0].count)).toBe(0);
    expect(Number((await db`
      SELECT count(*) AS count FROM message_link_previews
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0].count)).toBe(0);
  });
});
