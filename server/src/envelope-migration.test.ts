import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import {
  bodyAAD,
  chatFolderTitleAAD,
  draftBodyAAD,
  draftResponseAAD,
  installationPushTokenAAD,
  mediaChunkAAD,
  mediaFileNameAAD,
  mediaThumbnailAAD,
  pollAAD,
  linkPreviewAssetAAD,
  linkPreviewMetadataAAD,
  linkPreviewURLAAD,
  pushTokenAAD,
  reportActionNoteAAD,
  reportEvidenceAAD,
  scheduledItemAAD,
  seal,
  sessionRotationAAD,
  voipPushTokenAAD,
} from "./crypto";
import { makeSql } from "./db";
import { openForScope, resetEnvelopeCryptoInstancesForTests } from "./envelope-crypto";
import { ENVELOPE_MIGRATION_DOMAINS, migrateEnvelopeBatch } from "./envelope-migration";

const db = makeSql(process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test");

beforeEach(async () => {
  delete process.env.TOJ_CRYPTO_MODE;
  delete process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
  resetEnvelopeCryptoInstancesForTests();
  await db`TRUNCATE accounts, otp_challenges, link_preview_cache_entries,
    link_preview_snapshots, link_preview_assets, push_installations, service_data_keys,
    crypto_migration_cursors RESTART IDENTITY CASCADE`;
});

afterAll(async () => {
  delete process.env.TOJ_CRYPTO_MODE;
  delete process.env.TOJ_KEY_ENCRYPTION_PROVIDER;
  resetEnvelopeCryptoInstancesForTests();
  await db.close();
});

describe.serial("envelope ciphertext migration", () => {
  test("resumably migrates every retained ciphertext domain from the legacy key", async () => {
    const { code } = await startVerification(db, "+16505559333");
    const account = await checkVerification(db, "+16505559333", code!, "ios", "Migration iPhone", "Alice");
    const dialogId = crypto.randomUUID();
    const messageId = 1;
    const operationId = crypto.randomUUID();
    const mediaId = crypto.randomUUID();
    const reportId = crypto.randomUUID();
    const folderId = crypto.randomUUID();
    const deliveryId = crypto.randomUUID();
    const scheduledClientMessageId = crypto.randomUUID();
    const snapshotId = crypto.randomUUID();
    const assetId = crypto.randomUUID();
    const installationId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const rotationId = crypto.randomUUID();
    const lookup = Buffer.alloc(32, 0x31);
    const body = seal("message", bodyAAD(dialogId, messageId, account.accountId));
    const poll = seal(
      JSON.stringify({
        question: "Legacy poll", options: ["One", "Two"],
        correctOptionIndex: null, explanation: null,
      }),
      pollAAD(dialogId, messageId),
    );
    const draft = seal("draft", draftBodyAAD(account.accountId, dialogId, 1));
    const response = seal("{}", draftResponseAAD(account.accountId, operationId));
    const push = seal("aa".repeat(32), pushTokenAAD(account.deviceId));
    const voip = seal("bb".repeat(32), voipPushTokenAAD(account.deviceId));
    const installationPush = seal(
      "cc".repeat(32), installationPushTokenAAD(installationId, "normal"),
    );
    const installationVoIP = seal(
      "dd".repeat(32), installationPushTokenAAD(installationId, "voip"),
    );
    const rotationReceipt = seal(
      JSON.stringify({ tokenVersion: 2 }), sessionRotationAAD(sessionId, rotationId),
    );
    const fileName = seal("private.jpg", mediaFileNameAAD(mediaId));
    const thumbnail = seal(Buffer.from("thumb"), mediaThumbnailAAD(mediaId));
    const chunk = seal(Buffer.from("media"), mediaChunkAAD(mediaId, 0));
    const evidence = seal("{\"version\":1}", reportEvidenceAAD(reportId, account.accountId));
    const note = seal("sensitive", reportActionNoteAAD(reportId, "claimed", "operator"));
    const folderTitle = seal("Private", chatFolderTitleAAD(account.accountId, folderId));
    const scheduled = seal(
      JSON.stringify({ body: "later", replyToMsgId: null, mentions: [], linkPreviewCandidate: null }),
      scheduledItemAAD(account.accountId, deliveryId, 0, scheduledClientMessageId),
    );
    const cachedURL = seal(
      "https://example.com/",
      linkPreviewURLAAD("cache", lookup.toString("hex")),
    );
    const messageURL = seal(
      "https://example.com/",
      linkPreviewURLAAD("message", `${dialogId}:1:1`),
    );
    const snapshotURL = seal(
      JSON.stringify({ originalURL: "https://example.com/", finalURL: "https://example.com/" }),
      linkPreviewURLAAD("snapshot", snapshotId),
    );
    const snapshotMetadata = seal(
      JSON.stringify({ title: "Example", description: null, siteName: null, destinationHost: "example.com" }),
      linkPreviewMetadataAAD(snapshotId),
    );
    const asset = seal(Buffer.from("asset"), linkPreviewAssetAAD(assetId));

    await db.begin(async (tx) => {
      await tx`INSERT INTO dialogs(id, type, created_by, last_msg_id)
        VALUES (${dialogId}, 'saved', ${account.accountId}, 1)`;
      await tx`INSERT INTO dialog_members(dialog_id, account_id, role)
        VALUES (${dialogId}, ${account.accountId}, 'owner')`;
      await tx`INSERT INTO messages(
        dialog_id, msg_id, sender_account_id, sender_device_id, client_msg_id, kind,
        body_key_id, body_nonce, body_ciphertext
      ) VALUES (${dialogId}, 1, ${account.accountId}, ${account.deviceId},
        ${crypto.randomUUID()}, 'text', ${body.keyId}, ${body.nonce}, ${body.ciphertext})`;
      await tx`INSERT INTO message_polls(
        dialog_id, msg_id, payload_key_id, payload_nonce, payload_ciphertext,
        option_count, multiple_choice, anonymous, quiz
      ) VALUES (${dialogId}, 1, ${poll.keyId}, ${poll.nonce}, ${poll.ciphertext},
        2, FALSE, TRUE, FALSE)`;
      await tx`INSERT INTO account_dialog_drafts(
        account_id, dialog_id, state, body_key_id, body_nonce, body_ciphertext,
        revision, operation_id, source_device_id
      ) VALUES (${account.accountId}, ${dialogId}, 'active', ${draft.keyId}, ${draft.nonce},
        ${draft.ciphertext}, 1, ${operationId}, ${account.deviceId})`;
      await tx`INSERT INTO draft_mutation_requests(
        account_id, operation_id, dialog_id, payload_fingerprint, status, resulting_revision,
        response_key_id, response_nonce, response_ciphertext
      ) VALUES (${account.accountId}, ${operationId}, ${dialogId}, ${Buffer.alloc(32, 1)},
        'completed', 1, ${response.keyId}, ${response.nonce}, ${response.ciphertext})`;
      await tx`UPDATE devices SET
        push_token_key_id = ${push.keyId}, push_token_nonce = ${push.nonce},
        push_token_ciphertext = ${push.ciphertext},
        voip_push_token_key_id = ${voip.keyId}, voip_push_token_nonce = ${voip.nonce},
        voip_push_token_ciphertext = ${voip.ciphertext}
        WHERE id = ${account.deviceId}`;
      await tx`INSERT INTO push_installations(
        installation_id,
        normal_token_hash, normal_token_ciphertext, normal_token_nonce,
        normal_token_key_id, normal_environment,
        voip_token_hash, voip_token_ciphertext, voip_token_nonce,
        voip_token_key_id, voip_environment
      ) VALUES (${installationId}, ${Buffer.alloc(32, 0x41)}, ${installationPush.ciphertext},
        ${installationPush.nonce}, ${installationPush.keyId}, 'sandbox',
        ${Buffer.alloc(32, 0x42)}, ${installationVoIP.ciphertext},
        ${installationVoIP.nonce}, ${installationVoIP.keyId}, 'sandbox')`;
      await tx`INSERT INTO device_sessions(
        id, device_id, refresh_token_hash, absolute_expires_at
      ) VALUES (${sessionId}, ${account.deviceId}, ${Buffer.alloc(32, 0x43)},
        now() + interval '1 day')`;
      await tx`INSERT INTO session_rotation_receipts(
        session_id, rotation_id, request_token_digest,
        response_ciphertext, response_nonce, response_key_id,
        response_generation, expires_at
      ) VALUES (${sessionId}, ${rotationId}, ${Buffer.alloc(32, 0x44)},
        ${rotationReceipt.ciphertext}, ${rotationReceipt.nonce}, ${rotationReceipt.keyId},
        1, now() + interval '5 minutes')`;
      await tx`INSERT INTO media_objects(
        id, owner_account_id, kind, content_type, file_name_key_id, file_name_nonce,
        file_name_ciphertext, byte_size, expected_sha256, uploaded_bytes, status,
        thumbnail_key_id, thumbnail_nonce, thumbnail_ciphertext
      ) VALUES (${mediaId}, ${account.accountId}, 'file', 'application/octet-stream',
        ${fileName.keyId}, ${fileName.nonce}, ${fileName.ciphertext}, 5, ${Buffer.alloc(32, 2)},
        5, 'ready', ${thumbnail.keyId}, ${thumbnail.nonce}, ${thumbnail.ciphertext})`;
      await tx`INSERT INTO media_chunks(
        media_id, chunk_offset, plain_size, plain_sha256, key_id, nonce, ciphertext
      ) VALUES (${mediaId}, 0, 5, ${Buffer.alloc(32, 3)}, ${chunk.keyId}, ${chunk.nonce},
        ${chunk.ciphertext})`;
      await tx`INSERT INTO abuse_reports(
        id, reporter_account_id, client_report_id, request_fingerprint, dialog_id,
        subject_type, reported_account_id, reason, priority, status,
        evidence_key_id, evidence_nonce, evidence_ciphertext, evidence_plain_size
      ) VALUES (${reportId}, ${account.accountId}, ${crypto.randomUUID()}, ${Buffer.alloc(32, 4)},
        ${dialogId}, 'account', ${account.accountId}, 'spam', 'standard', 'open',
        ${evidence.keyId}, ${evidence.nonce}, ${evidence.ciphertext}, 13)`;
      await tx`INSERT INTO abuse_report_actions(
        report_id, actor_kind, actor_id, action, note_key_id, note_nonce, note_ciphertext
      ) VALUES (${reportId}, 'moderation', 'operator', 'claimed',
        ${note.keyId}, ${note.nonce}, ${note.ciphertext})`;
      await tx`INSERT INTO chat_folders(
        account_id, folder_id, title_key_id, title_nonce, title_ciphertext, icon, position, revision
      ) VALUES (${account.accountId}, ${folderId}, ${folderTitle.keyId}, ${folderTitle.nonce},
        ${folderTitle.ciphertext}, 'folder', 0, 1)`;
      await tx`INSERT INTO scheduled_deliveries(
        id, account_id, origin_device_id, dialog_id, deliver_at, available_at, revision
      ) VALUES (${deliveryId}, ${account.accountId}, ${account.deviceId}, ${dialogId},
        now() + interval '1 hour', now() + interval '1 hour', 1)`;
      await tx`INSERT INTO scheduled_delivery_items(
        delivery_id, item_index, client_msg_id, kind,
        payload_key_id, payload_nonce, payload_ciphertext
      ) VALUES (${deliveryId}, 0, ${scheduledClientMessageId}, 'text',
        ${scheduled.keyId}, ${scheduled.nonce}, ${scheduled.ciphertext})`;
      await tx`INSERT INTO link_preview_assets(
        id, key_id, nonce, ciphertext, content_type, byte_size, width, height, digest_hmac
      ) VALUES (${assetId}, ${asset.keyId}, ${asset.nonce}, ${asset.ciphertext}, 'image/jpeg',
        5, 1, 1, ${Buffer.alloc(32, 0x32)})`;
      await tx`INSERT INTO link_preview_snapshots(
        id, url_key_id, url_nonce, url_ciphertext,
        metadata_key_id, metadata_nonce, metadata_ciphertext, asset_id, expires_at
      ) VALUES (${snapshotId}, ${snapshotURL.keyId}, ${snapshotURL.nonce},
        ${snapshotURL.ciphertext}, ${snapshotMetadata.keyId}, ${snapshotMetadata.nonce},
        ${snapshotMetadata.ciphertext}, ${assetId}, now() + interval '1 day')`;
      await tx`INSERT INTO link_preview_cache_entries(
        url_lookup_hmac, url_key_id, url_nonce, url_ciphertext, state,
        current_snapshot_id, expires_at
      ) VALUES (${lookup}, ${cachedURL.keyId}, ${cachedURL.nonce}, ${cachedURL.ciphertext},
        'ready', ${snapshotId}, now() + interval '1 day')`;
      await tx`INSERT INTO message_link_previews(
        dialog_id, msg_id, generation, expected_edit_version, url_lookup_hmac,
        original_url_key_id, original_url_nonce, original_url_ciphertext, state, snapshot_id
      ) VALUES (${dialogId}, 1, 1, 0, ${lookup}, ${messageURL.keyId}, ${messageURL.nonce},
        ${messageURL.ciphertext}, 'ready', ${snapshotId})`;
    });

    process.env.TOJ_CRYPTO_MODE = "envelope";
    process.env.TOJ_KEY_ENCRYPTION_PROVIDER = "local";
    resetEnvelopeCryptoInstancesForTests();
    for (const domain of ENVELOPE_MIGRATION_DOMAINS) {
      const result = await migrateEnvelopeBatch(db, domain, { batchSize: 1 });
      expect({ domain, remaining: result.remaining }).toEqual({ domain, remaining: 0 });
      expect(result.migrated).toBe(1);
    }

    const keys = (await db`
      SELECT phone_key_id AS key_id FROM accounts WHERE id = ${account.accountId}
      UNION ALL SELECT body_key_id FROM messages WHERE dialog_id = ${dialogId}
      UNION ALL SELECT payload_key_id FROM message_polls WHERE dialog_id = ${dialogId}
      UNION ALL SELECT body_key_id FROM account_dialog_drafts WHERE account_id = ${account.accountId}
      UNION ALL SELECT response_key_id FROM draft_mutation_requests WHERE account_id = ${account.accountId}
      UNION ALL SELECT push_token_key_id FROM devices WHERE id = ${account.deviceId}
      UNION ALL SELECT voip_push_token_key_id FROM devices WHERE id = ${account.deviceId}
      UNION ALL SELECT normal_token_key_id FROM push_installations
        WHERE installation_id = ${installationId}
      UNION ALL SELECT voip_token_key_id FROM push_installations
        WHERE installation_id = ${installationId}
      UNION ALL SELECT response_key_id FROM session_rotation_receipts
        WHERE session_id = ${sessionId} AND rotation_id = ${rotationId}
      UNION ALL SELECT file_name_key_id FROM media_objects WHERE id = ${mediaId}
      UNION ALL SELECT thumbnail_key_id FROM media_objects WHERE id = ${mediaId}
      UNION ALL SELECT key_id FROM media_chunks WHERE media_id = ${mediaId}
      UNION ALL SELECT evidence_key_id FROM abuse_reports WHERE id = ${reportId}
      UNION ALL SELECT note_key_id FROM abuse_report_actions WHERE report_id = ${reportId}
      UNION ALL SELECT title_key_id FROM chat_folders WHERE folder_id = ${folderId}
      UNION ALL SELECT payload_key_id FROM scheduled_delivery_items WHERE delivery_id = ${deliveryId}
      UNION ALL SELECT url_key_id FROM link_preview_cache_entries WHERE url_lookup_hmac = ${lookup}
      UNION ALL SELECT original_url_key_id FROM message_link_previews
        WHERE dialog_id = ${dialogId} AND msg_id = 1
      UNION ALL SELECT url_key_id FROM link_preview_snapshots WHERE id = ${snapshotId}
      UNION ALL SELECT metadata_key_id FROM link_preview_snapshots WHERE id = ${snapshotId}
      UNION ALL SELECT key_id FROM link_preview_assets WHERE id = ${assetId}`)
      .map((row: any) => String(row.key_id));
    expect(keys).toHaveLength(22);
    expect(keys.every((keyId) => keyId !== "dev-v1")).toBeTrue();

    const migratedMessage = (await db`SELECT body_key_id, body_nonce, body_ciphertext
      FROM messages WHERE dialog_id = ${dialogId} AND msg_id = 1`)[0];
    expect((await openForScope(db, { kind: "account", accountId: account.accountId }, {
      keyId: migratedMessage.body_key_id,
      nonce: Buffer.from(migratedMessage.body_nonce),
      ciphertext: Buffer.from(migratedMessage.body_ciphertext),
    }, bodyAAD(dialogId, 1, account.accountId))).toString()).toBe("message");
  });

  test("yields a locked scope without deadlocking and resumes with the same cursor", async () => {
    const { code } = await startVerification(db, "+16505559334");
    const account = await checkVerification(
      db, "+16505559334", code!, "ios", "Contention iPhone", "Alice",
    );
    const dialogId = crypto.randomUUID();
    const body = seal("before rotation", bodyAAD(dialogId, 1, account.accountId));
    await db.begin(async (tx) => {
      await tx`INSERT INTO dialogs(id, type, created_by, last_msg_id)
        VALUES (${dialogId}, 'saved', ${account.accountId}, 1)`;
      await tx`INSERT INTO dialog_members(dialog_id, account_id, role)
        VALUES (${dialogId}, ${account.accountId}, 'owner')`;
      await tx`INSERT INTO messages(
        dialog_id, msg_id, sender_account_id, sender_device_id, client_msg_id, kind,
        body_key_id, body_nonce, body_ciphertext
      ) VALUES (${dialogId}, 1, ${account.accountId}, ${account.deviceId},
        ${crypto.randomUUID()}, 'text', ${body.keyId}, ${body.nonce}, ${body.ciphertext})`;
    });

    process.env.TOJ_CRYPTO_MODE = "envelope";
    process.env.TOJ_KEY_ENCRYPTION_PROVIDER = "local";
    resetEnvelopeCryptoInstancesForTests();

    let releaseFence!: () => void;
    const holdFence = new Promise<void>((resolve) => { releaseFence = resolve; });
    let fenceAcquired!: () => void;
    const fenceReady = new Promise<void>((resolve) => { fenceAcquired = resolve; });
    const blocker = db.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtextextended(
        ${`envelope-key:account:${account.accountId}`}, 0
      ))`;
      fenceAcquired();
      await holdFence;
    });
    await fenceReady;

    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const yielded = await Promise.race([
        migrateEnvelopeBatch(db, "messages", { batchSize: 1 }),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error("migration waited on the writer fence")), 2_000);
        }),
      ]);
      expect(yielded).toEqual({
        domain: "messages", migrated: 0, remaining: 1, retryable: true,
      });
      expect((await db`SELECT body_key_id FROM messages
        WHERE dialog_id = ${dialogId} AND msg_id = 1`)[0].body_key_id).toBe("dev-v1");
    } finally {
      if (timer) clearTimeout(timer);
      releaseFence();
      await blocker;
    }

    const resumed = await migrateEnvelopeBatch(db, "messages", { batchSize: 1 });
    expect(resumed).toEqual({
      domain: "messages", migrated: 1, remaining: 0, retryable: false,
    });
    const cursor = (await db`SELECT state, rows_migrated
      FROM crypto_migration_cursors WHERE domain = 'messages:dev-v1'`)[0];
    expect(cursor.state).toBe("complete");
    expect(Number(cursor.rows_migrated)).toBe(1);
  });

  test("acquires every scope fence before mutating a mixed-account batch", async () => {
    const firstVerification = await startVerification(db, "+16505559336");
    const firstAccount = await checkVerification(
      db, "+16505559336", firstVerification.code!, "ios", "First iPhone", "Alice",
    );
    const secondVerification = await startVerification(db, "+16505559337");
    const secondAccount = await checkVerification(
      db, "+16505559337", secondVerification.code!, "ios", "Second iPhone", "Bob",
    );
    const accounts = [firstAccount, secondAccount].sort((left, right) =>
      left.accountId.localeCompare(right.accountId));
    const dialogs = [
      { id: "00000000-0000-4000-8000-000000000036", account: accounts[0] },
      { id: "00000000-0000-4000-8000-000000000037", account: accounts[1] },
    ];
    await db.begin(async (tx) => {
      for (const [index, item] of dialogs.entries()) {
        const body = seal(
          `mixed account ${index + 1}`,
          bodyAAD(item.id, 1, item.account.accountId),
        );
        await tx`INSERT INTO dialogs(id, type, created_by, last_msg_id)
          VALUES (${item.id}, 'saved', ${item.account.accountId}, 1)`;
        await tx`INSERT INTO dialog_members(dialog_id, account_id, role)
          VALUES (${item.id}, ${item.account.accountId}, 'owner')`;
        await tx`INSERT INTO messages(
          dialog_id, msg_id, sender_account_id, sender_device_id, client_msg_id, kind,
          body_key_id, body_nonce, body_ciphertext
        ) VALUES (${item.id}, 1, ${item.account.accountId}, ${item.account.deviceId},
          ${crypto.randomUUID()}, 'text', ${body.keyId}, ${body.nonce}, ${body.ciphertext})`;
      }
    });

    process.env.TOJ_CRYPTO_MODE = "envelope";
    process.env.TOJ_KEY_ENCRYPTION_PROVIDER = "local";
    resetEnvelopeCryptoInstancesForTests();

    let releaseFence!: () => void;
    const holdFence = new Promise<void>((resolve) => { releaseFence = resolve; });
    let fenceAcquired!: () => void;
    const fenceReady = new Promise<void>((resolve) => { fenceAcquired = resolve; });
    const blockedAccountId = accounts[1].accountId;
    const blocker = db.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtextextended(
        ${`envelope-key:account:${blockedAccountId}`}, 0
      ))`;
      fenceAcquired();
      await holdFence;
    });
    await fenceReady;

    try {
      const yielded = await migrateEnvelopeBatch(db, "messages", { batchSize: 2 });
      expect(yielded).toEqual({
        domain: "messages", migrated: 0, remaining: 1, retryable: true,
      });
      expect((await db`SELECT body_key_id FROM messages
        WHERE dialog_id = ANY(${db.array(dialogs.map((item) => item.id), "uuid")}::uuid[])
        ORDER BY dialog_id`).map((row: any) => row.body_key_id)).toEqual(["dev-v1", "dev-v1"]);
    } finally {
      releaseFence();
      await blocker;
    }

    const resumed = await migrateEnvelopeBatch(db, "messages", { batchSize: 2 });
    expect(resumed).toEqual({
      domain: "messages", migrated: 2, remaining: 0, retryable: false,
    });
  });

  test("rolls back a failed batch and resumes after corrupt input is repaired", async () => {
    const { code } = await startVerification(db, "+16505559335");
    const account = await checkVerification(
      db, "+16505559335", code!, "ios", "Recovery iPhone", "Alice",
    );
    const dialogId = crypto.randomUUID();
    const first = seal("first", bodyAAD(dialogId, 1, account.accountId));
    const second = seal("second", bodyAAD(dialogId, 2, account.accountId));
    const corruptSecond = Buffer.from(second.ciphertext);
    corruptSecond[0] ^= 0xff;
    await db.begin(async (tx) => {
      await tx`INSERT INTO dialogs(id, type, created_by, last_msg_id)
        VALUES (${dialogId}, 'saved', ${account.accountId}, 2)`;
      await tx`INSERT INTO dialog_members(dialog_id, account_id, role)
        VALUES (${dialogId}, ${account.accountId}, 'owner')`;
      await tx`INSERT INTO messages(
        dialog_id, msg_id, sender_account_id, sender_device_id, client_msg_id, kind,
        body_key_id, body_nonce, body_ciphertext
      ) VALUES
        (${dialogId}, 1, ${account.accountId}, ${account.deviceId}, ${crypto.randomUUID()},
          'text', ${first.keyId}, ${first.nonce}, ${first.ciphertext}),
        (${dialogId}, 2, ${account.accountId}, ${account.deviceId}, ${crypto.randomUUID()},
          'text', ${second.keyId}, ${second.nonce}, ${corruptSecond})`;
    });

    process.env.TOJ_CRYPTO_MODE = "envelope";
    process.env.TOJ_KEY_ENCRYPTION_PROVIDER = "local";
    resetEnvelopeCryptoInstancesForTests();
    await expect(migrateEnvelopeBatch(db, "messages", { batchSize: 2 })).rejects.toThrow();
    expect((await db`SELECT body_key_id FROM messages WHERE dialog_id = ${dialogId}
      ORDER BY msg_id`).map((row: any) => row.body_key_id)).toEqual(["dev-v1", "dev-v1"]);
    expect((await db`SELECT 1 FROM crypto_migration_cursors
      WHERE domain = 'messages:dev-v1'`).length).toBe(0);

    await db`UPDATE messages SET body_ciphertext = ${second.ciphertext}
      WHERE dialog_id = ${dialogId} AND msg_id = 2`;
    const resumed = await migrateEnvelopeBatch(db, "messages", { batchSize: 2 });
    expect(resumed).toEqual({
      domain: "messages", migrated: 2, remaining: 0, retryable: false,
    });
    expect((await db`SELECT body_key_id FROM messages WHERE dialog_id = ${dialogId}`)
      .every((row: any) => row.body_key_id !== "dev-v1")).toBeTrue();
  });
});
