import { beforeEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { Client } from "pg";
import { checkVerification, startVerification } from "./auth";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import { updateDialogPreferences } from "./dialog-preferences";
import {
  DraftError,
  getDraft,
  purgeAccountDraftState,
  purgeRevokedDialogDraftState,
  putDraft,
} from "./drafts";
import {
  draftMutationReceiptKey,
  mediaGroupReceiptKey,
} from "./locks";
import { cancelMediaUpload, downloadMediaChunk } from "./media";
import { registerPushToken } from "./push";
import {
  ALLOWED_MUTATION_INGRESS_PER_MINUTE,
  CLEANUP_BATCH_SIZE,
  MAINTENANCE_INTERVAL_MS,
  cleanupExpiredData,
} from "./ops";
import {
  getBootstrapDialogsPage,
  getDifference,
  getOrCreateDirectDialog,
  sendMediaGroup,
  sendMessage,
  startBootstrap,
} from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function waitUntilReceiptLockIsHeld(key: string): Promise<void> {
  const probe = new Client({ connectionString: TEST_URL });
  await probe.connect();
  try {
    for (let attempt = 0; attempt < 200; attempt += 1) {
      const result = await probe.query<{ acquired: boolean }>(
        "SELECT pg_try_advisory_lock(hashtextextended($1, 0)) AS acquired",
        [key],
      );
      if (!result.rows[0]?.acquired) return;
      await probe.query(
        "SELECT pg_advisory_unlock(hashtextextended($1, 0))",
        [key],
      );
      await Bun.sleep(5);
    }
    throw new Error(`receipt lock was not acquired: ${key}`);
  } finally {
    await probe.end();
  }
}

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function makeAccount(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name}'s iPhone`, name);
}

async function addDevice(accountId: string) {
  const row = (await db`
    INSERT INTO devices (account_id, platform, device_name, auth_token_hash)
    VALUES (${accountId}, 'ios', 'Second iPhone', gen_random_bytes(32))
    RETURNING id`)[0];
  return String(row.id);
}

async function readyMedia(accountId: string, kind: "photo" | "video" | "file" = "photo") {
  const row = (await db`
    INSERT INTO media_objects (
      owner_account_id, kind, content_type, byte_size, expected_sha256, uploaded_bytes,
      status, purpose, completed_at, expires_at
    )
    VALUES (
      ${accountId}, ${kind},
      ${kind === "file" ? "application/pdf" : kind === "video" ? "video/mp4" : "image/jpeg"},
      8, ${Buffer.alloc(32, 7)}, 8, 'ready', 'message', now(), 'infinity'
    )
    RETURNING id`)[0];
  return String(row.id);
}

async function pair() {
  const alice = await makeAccount("+16505557001", "Alice");
  const bob = await makeAccount("+16505557002", "Bob");
  const dialog = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
  return { alice, bob, dialogId: dialog.dialogId };
}

describe("cloud drafts and media groups", () => {
  beforeEach(resetDb);

  test("drafts are encrypted, exactly idempotent, private, and included in sync/bootstrap", async () => {
    const { alice, bob, dialogId } = await pair();
    const mediaId = await readyMedia(alice.accountId);
    const operationId = crypto.randomUUID();
    const attachmentId = crypto.randomUUID();
    const first = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId,
      state: "active",
      text: "raw  draft \n",
      replyToMsgId: null,
      mentions: [],
      attachments: [{ attachment_id: attachmentId, media_id: mediaId, position: 0 }],
    });
    expect(first.duplicate).toBe(false);
    expect(first.draft.text).toBe("raw  draft \n");
    expect(first.draft.attachments.map((item) => item.media_id)).toEqual([mediaId]);

    const stored = (await db`
      SELECT body_ciphertext, revision FROM account_dialog_drafts
      WHERE account_id = ${alice.accountId} AND dialog_id = ${dialogId}`)[0];
    expect(Buffer.from(stored.body_ciphertext).includes(Buffer.from("raw  draft"))).toBe(false);
    expect(Number(stored.revision)).toBe(first.draft.revision);

    const duplicate = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId,
      state: "active",
      text: "raw  draft \n",
      mentions: [],
      attachments: [{ attachment_id: attachmentId, media_id: mediaId, position: 0 }],
    });
    expect(duplicate).toEqual({ ...first, duplicate: true, pushes: [] });
    await expect(putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId,
      state: "active",
      text: "different",
    })).rejects.toMatchObject({
      status: 409,
      code: "draft_idempotency_conflict",
    } satisfies Partial<DraftError>);

    const aliceDifference = await getDifference(db, alice.accountId, first.draft.revision - 1);
    expect(aliceDifference.kind).toBe("difference");
    if (aliceDifference.kind === "difference") {
      expect(aliceDifference.updates).toContainEqual(expect.objectContaining({
        type: "draft.updated",
        dialog_id: dialogId,
        draft: expect.objectContaining({ text: "raw  draft \n", revision: first.draft.revision }),
      }));
    }
    const bobDifference = await getDifference(db, bob.accountId, 0);
    if (bobDifference.kind === "difference") {
      expect(bobDifference.updates.some((update) => update.type === "draft.updated")).toBe(false);
    }
    expect(await getDraft(db, bob.accountId, dialogId)).toBeNull();

    const bootstrap = await startBootstrap(db, alice.accountId);
    const page = await getBootstrapDialogsPage(db, alice.accountId, bootstrap.token);
    expect(page.dialogs[0].draft).toEqual(expect.objectContaining({
      operation_id: operationId,
      text: "raw  draft \n",
    }));
  });

  test("concurrent device commits converge by the account pts revision and clears remain tombstones", async () => {
    const { alice, dialogId } = await pair();
    const secondDeviceId = await addDevice(alice.accountId);
    const writes = await Promise.all([
      putDraft(db, {
        accountId: alice.accountId,
        deviceId: alice.deviceId,
        dialogId,
        operationId: crypto.randomUUID(),
        state: "active",
        text: "device one",
      }),
      putDraft(db, {
        accountId: alice.accountId,
        deviceId: secondDeviceId,
        dialogId,
        operationId: crypto.randomUUID(),
        state: "active",
        text: "device two",
      }),
    ]);
    const winner = writes.reduce((left, right) =>
      left.draft.revision > right.draft.revision ? left : right
    );
    expect(await getDraft(db, alice.accountId, dialogId)).toEqual(winner.draft);

    const cleared = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      state: "active",
      text: " \n\t ",
    });
    expect(cleared.draft.state).toBe("cleared");
    expect(cleared.draft.revision).toBeGreaterThan(winner.draft.revision);
    expect(await db`
      SELECT state FROM account_dialog_drafts
      WHERE account_id = ${alice.accountId} AND dialog_id = ${dialogId}`)
      .toEqual([expect.objectContaining({ state: "cleared" })]);
  });

  test("cleanup then newer write then stale retry cannot allocate pts or replace the newer draft", async () => {
    const { alice, dialogId } = await pair();
    const oldOperationId = crypto.randomUUID();
    const old = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: oldOperationId,
      text: "old generation",
    });
    await db`
      UPDATE draft_mutation_requests SET created_at = now() - interval '25 hours'
      WHERE account_id = ${alice.accountId} AND operation_id = ${oldOperationId}`;
    const cleanup = await cleanupExpiredData(db);
    expect(cleanup.draftMutations).toBe(1);
    expect(await db`
      SELECT operation_id FROM draft_mutation_tombstones
      WHERE account_id = ${alice.accountId} AND operation_id = ${oldOperationId}`)
      .toHaveLength(1);

    const newer = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "newer cross-device value",
    });
    const beforePts = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0].pts);
    const staleRetry = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: oldOperationId,
      text: "old generation",
    });
    const afterPts = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0].pts);
    expect(staleRetry.duplicate).toBe(true);
    expect(staleRetry.draft.operation_id).toBe(newer.draft.operation_id);
    expect(staleRetry.draft.text).toBe("newer cross-device value");
    expect(staleRetry.draft.revision).toBeGreaterThan(old.draft.revision);
    expect(afterPts).toBe(beforePts);
  });

  test("draft cleanup and a retry serialize across the live receipt and tombstone", async () => {
    const { alice, dialogId } = await pair();
    const operationId = crypto.randomUUID();
    const request = {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId,
      text: "serialized draft",
    };
    const first = await putDraft(db, request);
    await db`
      UPDATE draft_mutation_requests SET created_at = now() - interval '25 hours'
      WHERE account_id = ${alice.accountId} AND operation_id = ${operationId}`;

    // Hold the tombstone's unique-index entry open. Cleanup acquires the exact receipt lock and
    // then deterministically blocks on this insert; the retry must wait behind cleanup.
    const blocker = new Client({ connectionString: TEST_URL });
    await blocker.connect();
    await blocker.query("BEGIN");
    try {
      await blocker.query(
        `INSERT INTO draft_mutation_tombstones (
           account_id, operation_id, dialog_id, payload_fingerprint, fingerprint_key_id,
           resulting_revision
         )
         SELECT account_id, operation_id, dialog_id, payload_fingerprint, fingerprint_key_id,
                resulting_revision
         FROM draft_mutation_requests
         WHERE account_id = $1 AND operation_id = $2`,
        [alice.accountId, operationId],
      );
      const cleanupPromise = cleanupExpiredData(db);
      await waitUntilReceiptLockIsHeld(
        draftMutationReceiptKey(alice.accountId, operationId),
      );
      const retryPromise = putDraft(db, request);
      await blocker.query("COMMIT");
      const [cleaned, retry] = await Promise.all([cleanupPromise, retryPromise]);

      expect(cleaned.draftMutations).toBe(1);
      expect(retry.duplicate).toBe(true);
      expect(retry.draft.revision).toBe(first.draft.revision);
      expect(await db`
        SELECT operation_id FROM draft_mutation_requests
        WHERE account_id = ${alice.accountId} AND operation_id = ${operationId}`)
        .toHaveLength(0);
      expect(await db`
        SELECT operation_id FROM draft_mutation_tombstones
        WHERE account_id = ${alice.accountId} AND operation_id = ${operationId}`)
        .toHaveLength(1);
    } catch (error) {
      await blocker.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      await blocker.end();
    }
  });

  test("draft duplicate responses recheck current dialog authorization before returning content", async () => {
    const { alice, dialogId } = await pair();
    const operationId = crypto.randomUUID();
    const request = {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId,
      text: "must not leak",
    };
    await putDraft(db, request);
    await db`
      UPDATE dialog_members SET left_at = now()
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    await expect(putDraft(db, request)).rejects.toMatchObject({
      status: 403,
      code: "dialog_access_denied",
    });
  });

  test("a racing send can consume only its exact generation and never clears a newer device write", async () => {
    const { alice, dialogId } = await pair();
    const secondDeviceId = await addDevice(alice.accountId);
    const attempted = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "attempted generation",
    });
    const [, newer] = await Promise.all([
      sendMessage(db, {
        senderAccountId: alice.accountId,
        senderDeviceId: alice.deviceId,
        dialogId,
        clientMsgId: crypto.randomUUID(),
        body: "attempted generation",
        draftConsumeOperationId: attempted.draft.operation_id,
      }),
      putDraft(db, {
        accountId: alice.accountId,
        deviceId: secondDeviceId,
        dialogId,
        operationId: crypto.randomUUID(),
        text: "newer device generation",
      }),
    ]);
    const finalDraft = await getDraft(db, alice.accountId, dialogId);
    expect(finalDraft?.operation_id).toBe(newer.draft.operation_id);
    expect(finalDraft?.text).toBe("newer device generation");
    expect(finalDraft?.state).toBe("active");
  });

  test("group send allocates consecutive rows atomically, emits ordinary events, and consumes one draft generation", async () => {
    const { alice, bob, dialogId } = await pair();
    const mediaIds = [await readyMedia(alice.accountId), await readyMedia(alice.accountId, "file")];
    const draft = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      state: "active",
      text: "album caption",
      attachments: mediaIds.map((mediaId, position) => ({
        attachment_id: crypto.randomUUID(),
        media_id: mediaId,
        position,
      })),
    });
    const clientGroupId = crypto.randomUUID();
    const request = {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId,
      items: mediaIds.map((media_id) => ({ media_id })),
      body: draft.draft.text,
      draftConsumeOperationId: draft.draft.operation_id,
    };
    const sent = await sendMediaGroup(db, request);
    expect(sent.duplicate).toBe(false);
    expect(sent.messages).toHaveLength(2);
    expect(sent.messages[1].msg_id).toBe(sent.messages[0].msg_id + 1);
    expect(sent.messages.map((message) => message.media_group_index)).toEqual([0, 1]);
    expect(sent.messages.every((message) =>
      message.media_group_id === clientGroupId && message.media_group_count === 2
    )).toBe(true);
    expect(sent.messages.map((message) => message.text)).toEqual(["album caption", ""]);
    expect(sent.clearedDraftRevision).toBeGreaterThan(draft.draft.revision);
    expect((await getDraft(db, alice.accountId, dialogId))?.state).toBe("cleared");

    const duplicate = await sendMediaGroup(db, request);
    expect(duplicate.duplicate).toBe(true);
    expect(duplicate.messages.map((message) => message.msg_id))
      .toEqual(sent.messages.map((message) => message.msg_id));
    const recipientEvents = await db`
      SELECT type FROM account_events
      WHERE account_id = ${bob.accountId} AND type = 'message.new'
        AND msg_id BETWEEN ${sent.messages[0].msg_id} AND ${sent.messages[1].msg_id}`;
    expect(recipientEvents).toHaveLength(2);
    expect(await db`
      SELECT type FROM account_events
      WHERE account_id = ${bob.accountId} AND type = 'draft.updated'`).toHaveLength(0);
  });

  test("fallback media-group message IDs survive legacy blind-index retirement", async () => {
    const previousKeyring = process.env.TOJ_BLIND_INDEX_KEYRING;
    const previousActive = process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
    const previousDisabled = process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED;
    const previousProtocolKey = process.env.TOJ_PROTOCOL_ID_KEY;
    try {
      process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
        "lookup-v2": Buffer.alloc(32, 0x5a).toString("base64"),
      });
      process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "lookup-v2";
      process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED = "1";
      process.env.TOJ_PROTOCOL_ID_KEY = Buffer.alloc(32, 0x0b).toString("base64");
      const { alice, dialogId } = await pair();
      const mediaIds = [await readyMedia(alice.accountId), await readyMedia(alice.accountId)];
      const request = {
        senderAccountId: alice.accountId,
        senderDeviceId: alice.deviceId,
        dialogId,
        clientGroupId: crypto.randomUUID(),
        items: mediaIds.map((media_id) => ({ media_id })),
        body: "rotated album",
      };
      const sent = await sendMediaGroup(db, request);
      expect(sent.duplicate).toBe(false);
      expect((await sendMediaGroup(db, request)).duplicate).toBe(true);
    } finally {
      if (previousKeyring == null) delete process.env.TOJ_BLIND_INDEX_KEYRING;
      else process.env.TOJ_BLIND_INDEX_KEYRING = previousKeyring;
      if (previousActive == null) delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
      else process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = previousActive;
      if (previousDisabled == null) delete process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED;
      else process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED = previousDisabled;
      if (previousProtocolKey == null) delete process.env.TOJ_PROTOCOL_ID_KEY;
      else process.env.TOJ_PROTOCOL_ID_KEY = previousProtocolKey;
    }
  });

  test("silent media groups stay silent and cannot collide with alerting idempotency", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerPushToken(db, bob.deviceId, "44".repeat(32), "sandbox");
    const mediaIds = [await readyMedia(alice.accountId), await readyMedia(alice.accountId)];
    const request = {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId: crypto.randomUUID(),
      items: mediaIds.map((media_id) => ({ media_id })),
      body: "quiet album",
      silent: true,
    };
    const sent = await sendMediaGroup(db, request);
    const bobPts = sent.pushes
      .filter((push) => push.accountId === bob.accountId)
      .map((push) => push.pts);
    const deliveries = await db`
      SELECT alert FROM push_deliveries
      WHERE account_id = ${bob.accountId}
        AND pts = ANY(${db.array(bobPts, "int8")}::bigint[])
      ORDER BY pts`;
    expect(deliveries).toHaveLength(2);
    expect(deliveries.every((row: any) => row.alert === false)).toBe(true);
    expect((await sendMediaGroup(db, request)).duplicate).toBe(true);
    await expect(sendMediaGroup(db, { ...request, silent: false }))
      .rejects.toMatchObject({ status: 409, code: "media_group_idempotency_conflict" });
  });

  test("silent single-media sends stay silent and retain distinct idempotency", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerPushToken(db, bob.deviceId, "45".repeat(32), "sandbox");
    const request = {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      kind: "photo",
      mediaId: await readyMedia(alice.accountId),
      body: "quiet photo",
      silent: true,
    };
    const sent = await sendMessage(db, request);
    const bobPts = sent.pushes.find((push) => push.accountId === bob.accountId)?.pts;
    expect(bobPts).toBeNumber();
    expect((await db`
      SELECT alert FROM push_deliveries
      WHERE account_id = ${bob.accountId} AND pts = ${bobPts!}`)[0].alert).toBe(false);
    expect((await sendMessage(db, request)).duplicate).toBe(true);
    await expect(sendMessage(db, { ...request, silent: false }))
      .rejects.toMatchObject({ status: 409, code: "send_idempotency_conflict" });

    const historical = {
      ...request,
      clientMsgId: crypto.randomUUID(),
      mediaId: await readyMedia(alice.accountId),
      silent: false,
    };
    const historicalSend = await sendMessage(db, historical);
    await db`
      UPDATE send_requests SET fingerprint = NULL
      WHERE sender_account_id = ${alice.accountId}
        AND client_msg_id = ${historical.clientMsgId}`;
    await db`
      UPDATE messages SET send_fingerprint = NULL
      WHERE dialog_id = ${dialogId} AND msg_id = ${historicalSend.msgId}`;
    expect((await sendMessage(db, historical)).duplicate).toBe(true);
    await expect(sendMessage(db, { ...historical, silent: true }))
      .rejects.toMatchObject({ status: 409, code: "send_idempotency_conflict" });
  });

  test("single-message retries normalize link-preview aliases and object key order", async () => {
    const { alice, dialogId } = await pair();
    const url = "https://example.com";
    const body = `visit ${url}`;
    const request = {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body,
      linkPreviewsEnabled: true,
      linkPreviewCandidate: {
        url,
        utf16_offset: 6,
        utf16_length: url.length,
        disabled: false,
      },
    };
    const sent = await sendMessage(db, request);
    const duplicate = await sendMessage(db, {
      ...request,
      linkPreviewCandidate: {
        disabled: false,
        utf16Length: url.length,
        url,
        utf16Offset: 6,
      },
    });
    expect(duplicate.duplicate).toBe(true);
    expect(duplicate.msgId).toBe(sent.msgId);
  });

  test("one invalid group item rolls back before consuming ids or the draft", async () => {
    const { alice, dialogId } = await pair();
    const validMediaId = await readyMedia(alice.accountId);
    const invalidMediaId = crypto.randomUUID();
    const draft = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "keep me",
    });
    const before = Number((await db`SELECT last_msg_id FROM dialogs WHERE id = ${dialogId}`)[0].last_msg_id);
    await expect(sendMediaGroup(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId: crypto.randomUUID(),
      items: [{ media_id: validMediaId }, { media_id: invalidMediaId }],
      draftConsumeOperationId: draft.draft.operation_id,
    })).rejects.toMatchObject({ code: "media_group_item_unavailable" });
    expect(Number((await db`SELECT last_msg_id FROM dialogs WHERE id = ${dialogId}`)[0].last_msg_id))
      .toBe(before);
    expect((await getDraft(db, alice.accountId, dialogId))?.text).toBe("keep me");
  });

  test("draft media is owner-private, live while referenced, and receives a 24-hour dereference grace", async () => {
    const { alice, bob, dialogId } = await pair();
    const mediaId = await readyMedia(alice.accountId);
    await db`
      UPDATE media_objects
      SET completed_at = now() - interval '2 days',
          last_accessed_at = now() - interval '2 days'
      WHERE id = ${mediaId}`;
    await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "",
      attachments: [{
        attachment_id: crypto.randomUUID(),
        media_id: mediaId,
        position: 0,
      }],
    });

    expect((await downloadMediaChunk(db, alice.accountId, mediaId, 8)).bytes).toHaveLength(0);
    await expect(downloadMediaChunk(db, bob.accountId, mediaId, 8))
      .rejects.toMatchObject({ status: 404 });
    await expect(cancelMediaUpload(db, alice.accountId, alice.deviceId, mediaId))
      .rejects.toMatchObject({ status: 409 });
    await cleanupExpiredData(db);
    expect(await db`SELECT id FROM media_objects WHERE id = ${mediaId}`).toHaveLength(1);

    await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      state: "cleared",
      text: "",
    });
    await cleanupExpiredData(db);
    expect(await db`SELECT id FROM media_objects WHERE id = ${mediaId}`).toHaveLength(1);

    await db`
      UPDATE media_objects SET last_accessed_at = now() - interval '25 hours'
      WHERE id = ${mediaId}`;
    await cleanupExpiredData(db);
    expect(await db`SELECT id FROM media_objects WHERE id = ${mediaId}`).toHaveLength(0);
  });

  test("capability flags advertise drafts and media groups independently", async () => {
    const oldDrafts = process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED;
    const oldGroups = process.env.TOJ_MEDIA_GROUPS_V1_ENABLED;
    process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED = "1";
    delete process.env.TOJ_MEDIA_GROUPS_V1_ENABLED;
    const server = startCloudServer(0, db, null, null);
    try {
      const response = await fetch(`http://127.0.0.1:${server.port}/v1/capabilities`);
      const body = await response.json() as { api_version: number; capabilities: string[] };
      expect(body.api_version).toBe(6);
      expect(body.capabilities).toContain("cloud_drafts_v1");
      expect(body.capabilities).not.toContain("media_groups_v1");
    } finally {
      server.stop(true);
      if (oldDrafts == null) delete process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED;
      else process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED = oldDrafts;
      if (oldGroups == null) delete process.env.TOJ_MEDIA_GROUPS_V1_ENABLED;
      else process.env.TOJ_MEDIA_GROUPS_V1_ENABLED = oldGroups;
    }
  });

  test("request fingerprints are keyed, versioned, and not plaintext-derived SHA-256", async () => {
    const { alice, dialogId } = await pair();
    const operationId = crypto.randomUUID();
    await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId,
      state: "active",
      text: "fingerprint secret",
      mentions: [],
      attachments: [],
    });
    const stored = (await db`
      SELECT payload_fingerprint FROM draft_mutation_requests
      WHERE account_id = ${alice.accountId} AND operation_id = ${operationId}`)[0];
    const raw = createHash("sha256").update(JSON.stringify({
      dialog_id: dialogId,
      state: "active",
      text: "fingerprint secret",
      reply_to_msg_id: null,
      mentions: [],
      attachments: [],
    })).digest();
    expect(Buffer.from(stored.payload_fingerprint).equals(raw)).toBe(false);
    expect(Buffer.from(stored.payload_fingerprint)).toHaveLength(32);
  });

  test("group retry reconstructs an exact duplicate after the request row expires", async () => {
    const { alice, dialogId } = await pair();
    const mediaIds = [await readyMedia(alice.accountId), await readyMedia(alice.accountId)];
    const clientGroupId = crypto.randomUUID();
    const items = mediaIds.map((media_id) => ({
      media_id,
      client_msg_id: crypto.randomUUID(),
    }));
    const request = {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId,
      items,
      body: "durable duplicate",
    };
    const first = await sendMediaGroup(db, request);
    await db`
      UPDATE media_group_send_requests SET created_at = now() - interval '25 hours'
      WHERE sender_account_id = ${alice.accountId} AND client_group_id = ${clientGroupId}`;
    expect((await cleanupExpiredData(db)).mediaGroupSends).toBe(1);
    expect(await db`
      SELECT client_group_id FROM media_group_send_tombstones
      WHERE sender_account_id = ${alice.accountId} AND client_group_id = ${clientGroupId}`)
      .toHaveLength(1);
    const reconstructed = await sendMediaGroup(db, request);
    expect(reconstructed.duplicate).toBe(true);
    expect(reconstructed.messages.map((message) => message.msg_id))
      .toEqual(first.messages.map((message) => message.msg_id));
    expect(await db`
      SELECT msg_id FROM messages
      WHERE sender_account_id = ${alice.accountId} AND media_group_id = ${clientGroupId}`)
      .toHaveLength(2);
  });

  test("media-group cleanup and retry serialize across the live receipt and tombstone", async () => {
    const { alice, dialogId } = await pair();
    const mediaIds = [await readyMedia(alice.accountId), await readyMedia(alice.accountId)];
    const clientGroupId = crypto.randomUUID();
    const request = {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId,
      items: mediaIds.map((media_id) => ({ media_id })),
      body: "serialized group",
    };
    const first = await sendMediaGroup(db, request);
    await db`
      UPDATE media_group_send_requests SET created_at = now() - interval '25 hours'
      WHERE sender_account_id = ${alice.accountId} AND client_group_id = ${clientGroupId}`;

    const blocker = new Client({ connectionString: TEST_URL });
    await blocker.connect();
    await blocker.query("BEGIN");
    try {
      await blocker.query(
        `INSERT INTO media_group_send_tombstones (
           sender_account_id, client_group_id, dialog_id, payload_fingerprint,
           fingerprint_key_id, first_msg_id, last_msg_id, sender_pts, cleared_draft_revision
         )
         SELECT sender_account_id, client_group_id, dialog_id, payload_fingerprint,
                fingerprint_key_id, first_msg_id, last_msg_id, sender_pts,
                cleared_draft_revision
         FROM media_group_send_requests
         WHERE sender_account_id = $1 AND client_group_id = $2`,
        [alice.accountId, clientGroupId],
      );
      const cleanupPromise = cleanupExpiredData(db);
      await waitUntilReceiptLockIsHeld(
        mediaGroupReceiptKey(alice.accountId, clientGroupId),
      );
      const retryPromise = sendMediaGroup(db, request);
      await blocker.query("COMMIT");
      const [cleaned, retry] = await Promise.all([cleanupPromise, retryPromise]);

      expect(cleaned.mediaGroupSends).toBe(1);
      expect(retry.duplicate).toBe(true);
      expect(retry.messages.map((message) => message.msg_id))
        .toEqual(first.messages.map((message) => message.msg_id));
      expect(await db`
        SELECT msg_id FROM messages
        WHERE sender_account_id = ${alice.accountId}
          AND media_group_id = ${clientGroupId}
        ORDER BY msg_id`)
        .toHaveLength(2);
    } catch (error) {
      await blocker.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      await blocker.end();
    }
  });

  test("group retries use deterministic item ids and recheck access before any duplicate content", async () => {
    const { alice, dialogId } = await pair();
    const mediaIds = [await readyMedia(alice.accountId), await readyMedia(alice.accountId)];
    const request = {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId: crypto.randomUUID(),
      items: mediaIds.map((media_id) => ({ media_id })),
      body: "stable ids",
    };
    const first = await sendMediaGroup(db, request);
    const duplicate = await sendMediaGroup(db, request);
    expect(duplicate.messages.map((message) => message.client_msg_id))
      .toEqual(first.messages.map((message) => message.client_msg_id));

    await db`
      UPDATE dialog_members SET left_at = now()
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    await expect(sendMediaGroup(db, request)).rejects.toMatchObject({
      status: 403,
      code: "dialog_access_denied",
    });
    await db`
      UPDATE dialog_members SET left_at = NULL
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    await db`
      DELETE FROM media_group_send_requests
      WHERE sender_account_id = ${alice.accountId}
        AND client_group_id = ${request.clientGroupId}`;
    expect((await sendMediaGroup(db, request)).duplicate).toBe(true);
    await db`
      UPDATE dialog_members SET left_at = now()
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    await expect(sendMediaGroup(db, request)).rejects.toMatchObject({
      status: 403,
      code: "dialog_access_denied",
    });
  });

  test("revocation and account deletion explicitly purge private draft state and draft-only media", async () => {
    const { alice, dialogId } = await pair();
    const firstMedia = await readyMedia(alice.accountId);
    await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "revoked",
      attachments: [{
        attachment_id: crypto.randomUUID(), media_id: firstMedia, position: 0,
      }],
    });
    await purgeRevokedDialogDraftState(db, alice.accountId, dialogId);
    expect(await getDraft(db, alice.accountId, dialogId)).toBeNull();
    expect(await db`SELECT id FROM media_objects WHERE id = ${firstMedia}`).toHaveLength(0);

    await db`
      UPDATE dialog_members SET left_at = NULL
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    const secondMedia = await readyMedia(alice.accountId);
    await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "delete account",
      attachments: [{
        attachment_id: crypto.randomUUID(), media_id: secondMedia, position: 0,
      }],
    });
    await purgeAccountDraftState(db, alice.accountId);
    expect(await db`SELECT 1 FROM account_dialog_drafts WHERE account_id = ${alice.accountId}`)
      .toHaveLength(0);
    expect(await db`SELECT 1 FROM draft_mutation_requests WHERE account_id = ${alice.accountId}`)
      .toHaveLength(0);
    expect(await db`SELECT 1 FROM draft_mutation_tombstones WHERE account_id = ${alice.accountId}`)
      .toHaveLength(0);
    expect(await db`SELECT id FROM media_objects WHERE id = ${secondMedia}`).toHaveLength(0);
  });

  test("raw old-node account deletion purges merged private state and only orphaned media", async () => {
    const { alice, bob, dialogId } = await pair();
    const orphanDraftMedia = await readyMedia(alice.accountId);
    const sharedMessageMedia = await readyMedia(alice.accountId);
    const dialogPhotoMedia = await readyMedia(alice.accountId);
    const unrelatedOwnedOrphan = await readyMedia(alice.accountId);
    const foreignMedia = await readyMedia(bob.accountId);

    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      kind: "photo",
      body: "",
      mediaId: sharedMessageMedia,
    });
    await db`
      UPDATE dialogs SET photo_media_id = ${dialogPhotoMedia}
      WHERE id = ${dialogId}`;
    const draftOperationId = crypto.randomUUID();
    await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: draftOperationId,
      text: "private draft",
      attachments: [
        {
          attachment_id: crypto.randomUUID(),
          media_id: orphanDraftMedia,
          position: 0,
        },
        {
          attachment_id: crypto.randomUUID(),
          media_id: sharedMessageMedia,
          position: 1,
        },
      ],
    });
    await db`
      INSERT INTO draft_mutation_tombstones (
        account_id, operation_id, dialog_id, payload_fingerprint, fingerprint_key_id,
        resulting_revision
      )
      SELECT account_id, operation_id, dialog_id, payload_fingerprint, fingerprint_key_id,
             resulting_revision
      FROM draft_mutation_requests
      WHERE account_id = ${alice.accountId}
        AND operation_id = ${draftOperationId}`;

    const groupMedia = [
      await readyMedia(alice.accountId),
      await readyMedia(alice.accountId),
    ];
    const clientGroupId = crypto.randomUUID();
    await sendMediaGroup(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId,
      items: groupMedia.map((media_id) => ({ media_id })),
      body: "retained album",
    });
    await db`
      INSERT INTO media_group_send_tombstones (
        sender_account_id, client_group_id, dialog_id, payload_fingerprint,
        fingerprint_key_id, first_msg_id, last_msg_id, sender_pts, cleared_draft_revision
      )
      SELECT sender_account_id, client_group_id, dialog_id, payload_fingerprint,
             fingerprint_key_id, first_msg_id, last_msg_id, sender_pts,
             cleared_draft_revision
      FROM media_group_send_requests
      WHERE sender_account_id = ${alice.accountId}
        AND client_group_id = ${clientGroupId}`;

    await updateDialogPreferences(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      clientMutationId: crypto.randomUUID(),
      patch: { pinned: true, muted: true, archived: true },
    });
    await db`
      INSERT INTO dialog_preference_legacy_reconciliation (dialog_id, account_id)
      VALUES (${dialogId}, ${alice.accountId})
      ON CONFLICT (dialog_id, account_id) DO NOTHING`;
    // Model a mixed-node retry whose canonical row was already removed. The account boundary must
    // not join through dialog_preferences when clearing this queue.
    await db`
      DELETE FROM dialog_preferences
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    await startBootstrap(db, alice.accountId);

    expect(await db`
      SELECT 1 FROM account_events
      WHERE account_id = ${alice.accountId}
        AND type IN ('draft.updated', 'dialog.preferences_updated')`)
      .not.toHaveLength(0);

    // This models a previous release that knows only the account status column. The database
    // trigger, not application cleanup code, must own the complete merged deletion boundary.
    await db`
      UPDATE accounts SET status = 'deleted'
      WHERE id = ${alice.accountId}`;

    for (const [table, accountColumn] of [
      ["account_dialog_drafts", "account_id"],
      ["draft_mutation_requests", "account_id"],
      ["draft_mutation_tombstones", "account_id"],
      ["draft_mutation_budgets", "account_id"],
      ["media_group_send_requests", "sender_account_id"],
      ["media_group_send_tombstones", "sender_account_id"],
      ["media_group_send_budgets", "account_id"],
      ["dialog_preferences", "account_id"],
      ["dialog_preference_requests", "account_id"],
      ["dialog_preference_action_budgets", "account_id"],
      ["dialog_preference_legacy_reconciliation", "account_id"],
      ["bootstrap_snapshots", "account_id"],
    ] as const) {
      expect(await db.unsafe(
        `SELECT 1 FROM public.${table} WHERE ${accountColumn} = $1`,
        [alice.accountId],
      ), table).toHaveLength(0);
    }
    expect(await db`
      SELECT 1 FROM account_events
      WHERE account_id = ${alice.accountId}
        AND type IN ('draft.updated', 'dialog.preferences_updated')`)
      .toHaveLength(0);

    expect(await db`
      SELECT id FROM media_objects
      WHERE id IN (${orphanDraftMedia}, ${unrelatedOwnedOrphan})`)
      .toHaveLength(0);
    const retained = await db`
      SELECT id FROM media_objects
      WHERE id IN (
        ${sharedMessageMedia},
        ${dialogPhotoMedia},
        ${groupMedia[0]},
        ${groupMedia[1]},
        ${foreignMedia}
      )
      ORDER BY id`;
    expect(new Set(retained.map((row: any) => String(row.id)))).toEqual(new Set([
      sharedMessageMedia,
      dialogPhotoMedia,
      ...groupMedia,
      foreignMedia,
    ]));
    expect(await db`
      SELECT msg_id FROM messages
      WHERE dialog_id = ${dialogId}
        AND media_id IN (
          ${sharedMessageMedia},
          ${groupMedia[0]},
          ${groupMedia[1]}
        )`).toHaveLength(3);
  });

  test("draft kill switch covers consumption, difference, and bootstrap without pts gaps", async () => {
    const { alice, dialogId } = await pair();
    const draft = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "hidden while killed",
    });
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "queued",
      draftConsumeOperationId: draft.draft.operation_id,
      allowDraftConsumption: false,
    })).rejects.toMatchObject({ status: 404, code: "capability_unavailable" });
    const difference = await getDifference(db, alice.accountId, draft.draft.revision - 1, {
      cloudDraftsEnabled: false,
    });
    expect(difference.kind).toBe("difference");
    if (difference.kind === "difference") {
      expect(difference.updates).toEqual([
        expect.objectContaining({
          pts: draft.draft.revision,
          ptsCount: 1,
          type: "capability.skipped",
        }),
      ]);
      expect(difference.state.pts).toBeGreaterThanOrEqual(draft.draft.revision);
    }
    const bootstrap = await startBootstrap(db, alice.accountId);
    const page = await getBootstrapDialogsPage(db, alice.accountId, bootstrap.token, {
      cloudDraftsEnabled: false,
    });
    expect(page.dialogs[0].draft).toBeNull();
    expect((await getDraft(db, alice.accountId, dialogId))?.text).toBe("hidden while killed");
  });

  test("album item budget is enforced independently of request count", async () => {
    const { alice, dialogId } = await pair();
    await db`
      INSERT INTO media_group_send_budgets(account_id, device_id, item_count)
      SELECT ${alice.accountId}, ${alice.deviceId}, 10
      FROM generate_series(1, 60)`;
    const mediaIds = [await readyMedia(alice.accountId), await readyMedia(alice.accountId)];
    await expect(sendMediaGroup(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId: crypto.randomUUID(),
      items: mediaIds.map((media_id) => ({ media_id })),
    })).rejects.toMatchObject({ status: 429, code: "media_group_rate_limited" });
  });

  test("cleanup skips locked orphan media and migration constraints complete once", async () => {
    expect(CLEANUP_BATCH_SIZE * 60_000 / MAINTENANCE_INTERVAL_MS)
      .toBeGreaterThan(ALLOWED_MUTATION_INGRESS_PER_MINUTE);
    const { alice } = await pair();
    const mediaId = await readyMedia(alice.accountId);
    await db`
      UPDATE media_objects SET completed_at = now() - interval '2 days',
        last_accessed_at = now() - interval '2 days'
      WHERE id = ${mediaId}`;
    await db.begin(async (tx) => {
      await tx`SELECT id FROM media_objects WHERE id = ${mediaId} FOR UPDATE`;
      const cleaned = await cleanupExpiredData(db);
      expect(cleaned.mediaOrphans).toBe(0);
    });
    expect(await db`SELECT id FROM media_objects WHERE id = ${mediaId}`).toHaveLength(1);
    const markers = await db`
      SELECT name FROM schema_migrations
      WHERE name IN (
        'media-constraints-v2',
        'messages-media-group-shape-v2',
        'messages-domain-constraints-v2',
        'account-events-type-v2',
        'account-events-type-v3',
        'message-mutation-operation-v2',
        'draft-request-dialog-fk-removal-v1',
        'media-group-request-dialog-fk-removal-v1',
        'account-private-cleanup-v1'
      )`;
    expect(markers).toHaveLength(9);
    const invalid = await db`
      SELECT conname FROM pg_constraint
      WHERE conname LIKE '%\\_v2' ESCAPE '\\' OR NOT convalidated`;
    expect(invalid).toHaveLength(0);
  });
});
