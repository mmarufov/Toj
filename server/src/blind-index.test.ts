import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import { checkVerification, resolveDevice, startVerification } from "./auth";
import {
  activeBlindIndex,
  blindIndexCandidates,
  blindIndexDatabaseReadiness,
  blindIndexForKey,
  blindIndexReadiness,
} from "./blind-index";
import { migratePhoneBlindIndexBatch } from "./blind-index-migration";
import { backfillBlindIndexKeyLabels } from "./blind-index-label-migration";
import { makeSql } from "./db";
import { getOrCreateDirectDialog, sendMessage } from "./sync";
import { cleanupExpiredData } from "./ops";
import { refreshV2Session, resolveV2Access, upgradeLegacySession } from "./session-security";
import { mutatePinnedMessage } from "./messaging-features";
import { registerInstallationPushToken } from "./push";

const originalKeyring = process.env.TOJ_BLIND_INDEX_KEYRING;
const originalActive = process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
const originalLegacyDisabled = process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED;
const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

beforeEach(async () => {
  delete process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED;
  await db`TRUNCATE accounts, otp_challenges, push_installations RESTART IDENTITY CASCADE`;
});

afterEach(() => {
  if (originalKeyring == null) delete process.env.TOJ_BLIND_INDEX_KEYRING;
  else process.env.TOJ_BLIND_INDEX_KEYRING = originalKeyring;
  if (originalActive == null) delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
  else process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = originalActive;
  if (originalLegacyDisabled == null) delete process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED;
  else process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED = originalLegacyDisabled;
});

afterAll(async () => {
  await db.close();
});

describe.serial("versioned blind-index keyring", () => {
  test("preserves legacy hashes and introduces an independently versioned active key", () => {
    delete process.env.TOJ_BLIND_INDEX_KEYRING;
    delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
    const legacy = activeBlindIndex("phone-lookup", "+16505550000");
    expect(legacy.keyId).toBe("legacy-v1");
    expect(legacy.digest).toEqual(
      createHmac("sha256", Buffer.alloc(32, 0x0b)).update("+16505550000").digest(),
    );

    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({ "lookup-v2": Buffer.alloc(32, 0x55).toString("base64") });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "lookup-v2";
    const active = activeBlindIndex("phone-lookup", "+16505550000");
    const candidates = blindIndexCandidates("phone-lookup", "+16505550000");
    expect(active.keyId).toBe("lookup-v2");
    expect(candidates.map((candidate) => candidate.keyId)).toEqual(["legacy-v1", "lookup-v2"]);
    expect(blindIndexForKey("lookup-v2", "phone-lookup", "+16505550000").digest)
      .toEqual(active.digest);
    expect(blindIndexReadiness().launchBlocking).toBeFalse();
  });

  test("supports a read-before-write rollout with legacy still active", () => {
    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "lookup-v2": Buffer.alloc(32, 0x55).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "legacy-v1";
    expect(activeBlindIndex("phone-lookup", "+16505550000").keyId).toBe("legacy-v1");
    expect(blindIndexCandidates("phone-lookup", "+16505550000").map((item) => item.keyId))
      .toEqual(["legacy-v1", "lookup-v2"]);
  });

  test("fails closed for an unknown historical key", () => {
    expect(() => blindIndexForKey("missing", "opaque-token", "secret"))
      .toThrow("unknown blind-index key ID");
  });

  test("removes legacy key material only through an explicit versioned-key cutover", () => {
    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "lookup-v2": Buffer.alloc(32, 0x56).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "lookup-v2";
    process.env.TOJ_BLIND_INDEX_LEGACY_DISABLED = "1";
    expect(blindIndexCandidates("phone-lookup", "+16505550000").map((item) => item.keyId))
      .toEqual(["lookup-v2"]);
    expect(() => blindIndexForKey("legacy-v1", "phone-lookup", "+16505550000"))
      .toThrow("unknown blind-index key ID legacy-v1");

    delete process.env.TOJ_BLIND_INDEX_KEYRING;
    delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
    expect(() => blindIndexReadiness())
      .toThrow("TOJ_BLIND_INDEX_KEYRING is required when legacy-v1 is disabled");
  });

  test("backfills unlabeled upgraded rows and preserves old-writer defaults", async () => {
    const first = await checkVerification(
      db, "+16505559311", (await startVerification(db, "+16505559311")).code,
      "ios", "Upgrade iPhone", "Upgrade",
    );
    const second = await checkVerification(
      db, "+16505559312", (await startVerification(db, "+16505559312")).code,
      "ios", "Peer iPhone", "Peer",
    );
    const dialog = await getOrCreateDirectDialog(db, first.accountId, second.accountId);
    const message = await sendMessage(db, {
      senderAccountId: second.accountId,
      senderDeviceId: second.deviceId,
      dialogId: dialog.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "upgrade fixture",
    });
    let verified = false;
    try {
      await db.begin(async (tx) => {
        await tx`ALTER TABLE devices DROP CONSTRAINT devices_push_hash_key_check`;
        await tx`ALTER TABLE devices DROP CONSTRAINT devices_voip_push_hash_key_check`;
        await tx`ALTER TABLE otp_challenges DROP CONSTRAINT otp_challenges_network_hash_key_check`;
        await tx`ALTER TABLE call_invite_attempts
          DROP CONSTRAINT call_invite_attempts_network_hash_key_check`;
        await tx`ALTER TABLE message_link_previews
          DROP CONSTRAINT message_link_previews_url_hash_key_check`;
        await tx`UPDATE devices SET
          push_token_hash = ${Buffer.alloc(32, 0x11)}, push_token_hash_key_id = NULL,
          voip_push_token_hash = ${Buffer.alloc(32, 0x12)}, voip_push_token_hash_key_id = NULL
          WHERE id = ${first.deviceId}`;
        await tx`INSERT INTO otp_challenges (
          phone_lookup_hash, code_hash, network_hash, network_key_id, expires_at
        ) VALUES (
          ${Buffer.alloc(32, 0x13)}, ${Buffer.alloc(32, 0x14)}, ${Buffer.alloc(32, 0x15)},
          NULL, now() + interval '5 minutes'
        )`;
        await tx`INSERT INTO call_invite_attempts (
          caller_account_id, callee_account_id, caller_device_id, network_hash, network_key_id
        ) VALUES (
          ${first.accountId}, ${second.accountId}, ${first.deviceId},
          ${Buffer.alloc(32, 0x16)}, NULL
        )`;
        await tx`INSERT INTO message_link_previews (
          dialog_id, msg_id, expected_edit_version, url_lookup_hmac, url_lookup_key_id, state
        ) VALUES (
          ${dialog.dialogId}, ${message.msgId}, 0, ${Buffer.alloc(32, 0x17)}, NULL, 'disabled'
        )`;

        const result = await backfillBlindIndexKeyLabels(tx, [
          "devices", "otp-network", "call-network", "message-preview-url",
        ], 1);
        expect(result).toMatchObject({
          devices: 1, "otp-network": 1, "call-network": 1, "message-preview-url": 1,
        });
        expect((await tx`SELECT push_token_hash_key_id, voip_push_token_hash_key_id
          FROM devices WHERE id = ${first.deviceId}`)[0]).toMatchObject({
          push_token_hash_key_id: "legacy-v1", voip_push_token_hash_key_id: "legacy-v1",
        });
        expect((await tx`SELECT network_key_id FROM otp_challenges
          WHERE network_hash = ${Buffer.alloc(32, 0x15)}`)[0].network_key_id).toBe("legacy-v1");
        expect((await tx`SELECT network_key_id FROM call_invite_attempts
          WHERE network_hash = ${Buffer.alloc(32, 0x16)}`)[0].network_key_id).toBe("legacy-v1");
        expect((await tx`SELECT url_lookup_key_id FROM message_link_previews
          WHERE dialog_id = ${dialog.dialogId} AND msg_id = ${message.msgId}`)[0]
          .url_lookup_key_id).toBe("legacy-v1");

        const oldWriter = (await tx`INSERT INTO call_invite_attempts (
          caller_account_id, callee_account_id, caller_device_id, network_hash
        ) VALUES (
          ${first.accountId}, ${second.accountId}, ${first.deviceId}, ${Buffer.alloc(32, 0x18)}
        ) RETURNING network_key_id`)[0];
        expect(oldWriter.network_key_id).toBe("legacy-v1");
        verified = true;
        throw new Error("rollback upgraded-row fixture");
      });
    } catch (error) {
      expect(String(error)).toContain("rollback upgraded-row fixture");
    }
    expect(verified).toBe(true);
  });

  test("rotates recoverable phone indexes and opportunistically rotates login credentials", async () => {
    delete process.env.TOJ_BLIND_INDEX_KEYRING;
    delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
    const firstPhone = "+16505559301";
    const secondPhone = "+16505559302";
    const firstCode = await startVerification(db, firstPhone);
    const first = await checkVerification(
      db, firstPhone, firstCode.code, "ios", "Legacy iPhone", "First",
    );
    const secondCode = await startVerification(db, secondPhone);
    const second = await checkVerification(
      db, secondPhone, secondCode.code, "ios", "Migration iPhone", "Second",
    );
    expect((await db`SELECT phone_lookup_key_id FROM accounts WHERE id = ${first.accountId}`)[0]
      .phone_lookup_key_id).toBe("legacy-v1");

    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "lookup-v2": Buffer.alloc(32, 0x55).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "lookup-v2";

    await resolveDevice(db, first.token);
    expect((await db`SELECT auth_token_key_id FROM devices WHERE id = ${first.deviceId}`)[0]
      .auth_token_key_id).toBe("lookup-v2");
    await db`UPDATE otp_challenges SET created_at = now() - interval '1 minute'`;
    const loginCode = await startVerification(db, firstPhone);
    await checkVerification(db, firstPhone, loginCode.code, "ios", "Rotated iPhone", "First");
    expect((await db`SELECT phone_lookup_key_id FROM accounts WHERE id = ${first.accountId}`)[0]
      .phone_lookup_key_id).toBe("lookup-v2");

    const migrated = await migratePhoneBlindIndexBatch(db, 100);
    expect(migrated).toMatchObject({
      activeKeyId: "lookup-v2", fromKeyId: "legacy-v1", hasMore: false,
    });
    expect(migrated.migrated).toBeGreaterThanOrEqual(1);
    expect((await db`SELECT phone_lookup_key_id FROM accounts WHERE id = ${second.accountId}`)[0]
      .phone_lookup_key_id).toBe("lookup-v2");

    expect((await blindIndexDatabaseReadiness(db)).ready).toBe(true);
    await db`UPDATE devices SET auth_token_key_id = 'retired-v0' WHERE id = ${second.deviceId}`;
    const unknown = await blindIndexDatabaseReadiness(db);
    expect(unknown.ready).toBe(false);
    expect(unknown.unknownKeyIds).toEqual(["retired-v0"]);

    await db`UPDATE devices SET auth_token_key_id = 'lookup-v2' WHERE id = ${second.deviceId}`;
    await db`INSERT INTO call_invite_attempts (
      caller_account_id, callee_account_id, caller_device_id, network_hash, network_key_id
    ) VALUES (
      ${first.accountId}, ${second.accountId}, ${first.deviceId}, ${Buffer.alloc(32, 0x44)},
      'retired-call'
    )`;
    const dialog = await getOrCreateDirectDialog(db, first.accountId, second.accountId);
    const message = await sendMessage(db, {
      senderAccountId: first.accountId,
      senderDeviceId: first.deviceId,
      dialogId: dialog.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "preview audit fixture",
    });
    await db`INSERT INTO message_link_previews (
      dialog_id, msg_id, expected_edit_version, url_lookup_hmac, url_lookup_key_id, state
    ) VALUES (
      ${dialog.dialogId}, ${message.msgId}, 0, ${Buffer.alloc(32, 0x45)},
      'retired-preview', 'disabled'
    )`;
    const crossDomain = await blindIndexDatabaseReadiness(db);
    expect(crossDomain.ready).toBe(false);
    // Disabled preview rows no longer perform deterministic lookup and therefore do not pin a
    // historical key; the still-live call-attempt budget does.
    expect(crossDomain.unknownKeyIds).toEqual(["retired-call"]);
  });

  test("keeps v2 access and refresh credentials valid across blind-index activation", async () => {
    delete process.env.TOJ_BLIND_INDEX_KEYRING;
    delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
    const legacy = await checkVerification(
      db, "+16505559303", (await startVerification(db, "+16505559303")).code,
      "ios", "Session iPhone", "Session",
    );
    const session = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);

    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "lookup-v2": Buffer.alloc(32, 0x57).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "lookup-v2";

    await expect(resolveV2Access(db, session.accessToken)).resolves.toMatchObject({
      accountId: legacy.accountId,
      deviceId: legacy.deviceId,
    });
    const rotated = await refreshV2Session(db, session.refreshToken, crypto.randomUUID());
    await expect(resolveV2Access(db, rotated.accessToken)).resolves.toMatchObject({
      deviceId: legacy.deviceId,
    });
    expect((await db`SELECT refresh_token_hash_key_id FROM device_sessions
      WHERE device_id = ${legacy.deviceId}`)[0].refresh_token_hash_key_id).toBe("lookup-v2");
    expect((await db`SELECT token_digest_key_id FROM session_access_tokens
      WHERE session_id = (SELECT id FROM device_sessions WHERE device_id = ${legacy.deviceId})
      ORDER BY created_at DESC LIMIT 1`)[0].token_digest_key_id).toBe("lookup-v2");
    expect((await db`SELECT request_token_digest_key_id FROM session_rotation_receipts
      WHERE session_id = (SELECT id FROM device_sessions WHERE device_id = ${legacy.deviceId})`)[0]
      .request_token_digest_key_id).toBe("legacy-v1");
  });

  test("keeps messaging-feature idempotency receipts valid across blind-index activation", async () => {
    delete process.env.TOJ_BLIND_INDEX_KEYRING;
    delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
    const first = await checkVerification(
      db, "+16505559304", (await startVerification(db, "+16505559304")).code,
      "ios", "Mutation iPhone", "Mutation",
    );
    const second = await checkVerification(
      db, "+16505559305", (await startVerification(db, "+16505559305")).code,
      "ios", "Peer iPhone", "Peer",
    );
    const dialog = await getOrCreateDirectDialog(db, first.accountId, second.accountId);
    const message = await sendMessage(db, {
      senderAccountId: first.accountId,
      senderDeviceId: first.deviceId,
      dialogId: dialog.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "pin across rotation",
    });
    const operationId = crypto.randomUUID();
    const input = {
      actorAccountId: first.accountId,
      actorDeviceId: first.deviceId,
      operationId,
      dialogId: dialog.dialogId,
      msgId: message.msgId,
      pinned: true,
      notifyMembers: false,
    };
    expect((await mutatePinnedMessage(db, input)).duplicate).toBe(false);

    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "lookup-v2": Buffer.alloc(32, 0x58).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "lookup-v2";

    expect((await mutatePinnedMessage(db, input)).duplicate).toBe(true);
    expect((await db`SELECT fingerprint_key_id FROM messaging_feature_mutations
      WHERE actor_account_id = ${first.accountId} AND operation_id = ${operationId}`)[0]
      .fingerprint_key_id).toBe("lookup-v2");
  });

  test("transfers an installation token across blind-index versions", async () => {
    delete process.env.TOJ_BLIND_INDEX_KEYRING;
    delete process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID;
    const account = await checkVerification(
      db, "+16505559306", (await startVerification(db, "+16505559306")).code,
      "ios", "Push iPhone", "Push",
    );
    const firstInstallationId = crypto.randomUUID();
    const secondInstallationId = crypto.randomUUID();
    const token = "ab".repeat(32);
    await registerInstallationPushToken(db, {
      accountId: account.accountId,
      deviceId: account.deviceId,
      installationId: firstInstallationId,
      token,
      environment: "sandbox",
      kind: "normal",
    });

    process.env.TOJ_BLIND_INDEX_KEYRING = JSON.stringify({
      "lookup-v2": Buffer.alloc(32, 0x59).toString("base64"),
    });
    process.env.TOJ_BLIND_INDEX_ACTIVE_KEY_ID = "lookup-v2";
    await registerInstallationPushToken(db, {
      accountId: account.accountId,
      deviceId: account.deviceId,
      installationId: secondInstallationId,
      token,
      environment: "sandbox",
      kind: "normal",
    });

    expect((await db`SELECT normal_token_hash, normal_token_hash_key_id
      FROM push_installations WHERE installation_id = ${firstInstallationId}`)[0])
      .toMatchObject({ normal_token_hash: null, normal_token_hash_key_id: null });
    expect((await db`SELECT normal_token_hash_key_id FROM push_installations
      WHERE installation_id = ${secondInstallationId}`)[0].normal_token_hash_key_id)
      .toBe("lookup-v2");
    expect(await db`SELECT installation_id FROM push_account_bindings
      WHERE device_id = ${account.deviceId}`).toEqual([
      expect.objectContaining({ installation_id: secondInstallationId }),
    ]);
  });

  test("expires durable send fingerprints without reusing the operation ID", async () => {
    const first = await checkVerification(
      db, "+16505559321", (await startVerification(db, "+16505559321")).code,
      "ios", "Receipt iPhone", "Receipt",
    );
    const second = await checkVerification(
      db, "+16505559322", (await startVerification(db, "+16505559322")).code,
      "ios", "Peer iPhone", "Peer",
    );
    const dialog = await getOrCreateDirectDialog(db, first.accountId, second.accountId);
    const clientMsgId = crypto.randomUUID();
    const input = {
      senderAccountId: first.accountId,
      senderDeviceId: first.deviceId,
      dialogId: dialog.dialogId,
      clientMsgId,
      body: "durable receipt",
    };
    const sent = await sendMessage(db, input);
    await db`UPDATE send_requests SET created_at = now() - interval '91 days'
      WHERE sender_account_id = ${first.accountId} AND client_msg_id = ${clientMsgId}`;
    await db`UPDATE messages SET server_ts = now() - interval '91 days'
      WHERE dialog_id = ${dialog.dialogId} AND msg_id = ${sent.msgId}`;
    const cleaned = await cleanupExpiredData(db, 100);
    expect(cleaned.blindIndexReceiptsExpired).toBeGreaterThanOrEqual(2);
    expect((await db`SELECT fingerprint, fingerprint_key_id FROM send_requests
      WHERE sender_account_id = ${first.accountId} AND client_msg_id = ${clientMsgId}`)[0])
      .toMatchObject({ fingerprint: null, fingerprint_key_id: "expired" });
    expect((await db`SELECT send_fingerprint, send_fingerprint_key_id FROM messages
      WHERE dialog_id = ${dialog.dialogId} AND msg_id = ${sent.msgId}`)[0])
      .toMatchObject({ send_fingerprint: null, send_fingerprint_key_id: "expired" });
    await expect(sendMessage(db, input)).rejects.toMatchObject({
      status: 409, code: "send_result_expired",
    });
    expect(await db`SELECT msg_id FROM messages WHERE dialog_id = ${dialog.dialogId}`)
      .toHaveLength(1);
  });
});
