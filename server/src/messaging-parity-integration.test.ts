import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, revokeDevice, startVerification } from "./auth";
import { makeSql } from "./db";
import { expireAcceptedMessages } from "./message-expiry";
import {
  closePoll,
  giphyClientConfiguration,
  getStickerCatalog,
  listPinnedMessages,
  listPollVoters,
  messagingFeatureFlagsForAccount,
  mutatePinnedMessage,
  setDialogAutoDelete,
  voteInPoll,
} from "./messaging-features";
import {
  buildVoIPAPNsPayload,
  processPushBatch,
  PushError,
  registerInstallationPushToken,
  registerInstallationVoIPPushToken,
  unregisterInstallationTokenKind,
  type APNsSendRequest,
  type APNsSendResult,
  type PushSender,
} from "./push";
import { getHistory, getOrCreateDirectDialog, sendMessage, SyncError } from "./sync";

process.env.TOJ_PRODUCTIVITY_WORKERS_DISABLED = "1";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

const FEATURE_ENVIRONMENT_KEYS = [
  "TOJ_PINNED_MESSAGES_ENABLED",
  "TOJ_PINNED_MESSAGES_ALLOWLIST",
  "TOJ_PINNED_MESSAGES_ROLLOUT_PERCENT",
  "TOJ_AUTO_DELETE_ENABLED",
  "TOJ_AUTO_DELETE_ALLOWLIST",
  "TOJ_AUTO_DELETE_ROLLOUT_PERCENT",
  "TOJ_POLLS_ENABLED",
  "TOJ_POLLS_ALLOWLIST",
  "TOJ_POLLS_ROLLOUT_PERCENT",
  "TOJ_STICKER_PACKS_ENABLED",
  "TOJ_STICKER_PACKS_ALLOWLIST",
  "TOJ_STICKER_PACKS_ROLLOUT_PERCENT",
  "TOJ_GIPHY_ENABLED",
  "TOJ_GIPHY_AGREEMENT_APPROVED",
  "TOJ_GIPHY_API_KEY",
  "TOJ_GIPHY_ALLOWLIST",
  "TOJ_GIPHY_ROLLOUT_PERCENT",
  "TOJ_MULTI_ACCOUNT_PUSH_ENABLED",
  "TOJ_MULTI_ACCOUNT_PUSH_ALLOWLIST",
  "TOJ_MULTI_ACCOUNT_PUSH_ROLLOUT_PERCENT",
] as const;

const originalFeatureEnvironment = new Map(
  FEATURE_ENVIRONMENT_KEYS.map((key) => [key, process.env[key]]),
);

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges, sticker_packs RESTART IDENTITY CASCADE`;
  for (const key of FEATURE_ENVIRONMENT_KEYS) delete process.env[key];
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function pair() {
  const alice = await account("+16505556101", "Alice");
  const bob = await account("+16505556102", "Bob");
  const dialog = await getOrCreateDirectDialog(
    db,
    alice.accountId,
    bob.accountId,
    alice.deviceId,
  );
  return { alice, bob, dialogId: dialog.dialogId };
}

function mutation(actor: { accountId: string; deviceId: string }) {
  return {
    actorAccountId: actor.accountId,
    actorDeviceId: actor.deviceId,
    operationId: crypto.randomUUID(),
  };
}

class RotatingSender implements PushSender {
  requests: APNsSendRequest[] = [];

  constructor(private readonly rotate: () => Promise<void>) {}

  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    this.requests.push(request);
    await this.rotate();
    return { status: 410, reason: "Unregistered" };
  }
}

describe("messaging parity integration", () => {
  beforeEach(resetDb);

  afterEach(() => {
    for (const [key, value] of originalFeatureEnvironment) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });

  test("all creation gates remain account-dark when switches are set without rollout", async () => {
    const alice = await account("+16505556110", "Alice");
    process.env.TOJ_PINNED_MESSAGES_ENABLED = "1";
    process.env.TOJ_AUTO_DELETE_ENABLED = "1";
    process.env.TOJ_POLLS_ENABLED = "1";
    process.env.TOJ_STICKER_PACKS_ENABLED = "1";
    process.env.TOJ_GIPHY_ENABLED = "1";
    process.env.TOJ_GIPHY_AGREEMENT_APPROVED = "1";
    process.env.TOJ_GIPHY_API_KEY = "test_client_key";
    process.env.TOJ_MULTI_ACCOUNT_PUSH_ENABLED = "1";

    expect(messagingFeatureFlagsForAccount(alice.accountId)).toEqual({
      pinnedMessages: false,
      autoDeleteCreation: false,
      polls: false,
      stickerPacks: false,
      giphy: false,
      multiAccountPush: false,
      support: false,
    });

    process.env.TOJ_PINNED_MESSAGES_ALLOWLIST = alice.accountId;
    process.env.TOJ_AUTO_DELETE_ALLOWLIST = alice.accountId;
    process.env.TOJ_POLLS_ALLOWLIST = alice.accountId;
    process.env.TOJ_STICKER_PACKS_ALLOWLIST = alice.accountId;
    process.env.TOJ_GIPHY_ALLOWLIST = alice.accountId;
    process.env.TOJ_MULTI_ACCOUNT_PUSH_ALLOWLIST = alice.accountId;
    const enabled = messagingFeatureFlagsForAccount(alice.accountId);
    expect(enabled).toMatchObject({
      pinnedMessages: true,
      autoDeleteCreation: true,
      polls: true,
      stickerPacks: true,
      giphy: true,
      multiAccountPush: true,
    });
  });

  test("send idempotency rejects changed content and structured forwards cannot bypass gates", async () => {
    const { alice, bob, dialogId } = await pair();
    const clientMsgId = crypto.randomUUID();
    const original = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId,
      body: "canonical",
    });
    const duplicate = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId,
      body: "canonical",
    });
    expect(duplicate.duplicate).toBe(true);
    expect(duplicate.msgId).toBe(original.msgId);

    let conflict: unknown;
    try {
      await sendMessage(db, {
        senderAccountId: alice.accountId,
        senderDeviceId: alice.deviceId,
        dialogId,
        clientMsgId,
        body: "changed after timeout",
      });
    } catch (error) {
      conflict = error;
    }
    expect(conflict).toBeInstanceOf(SyncError);
    expect((conflict as SyncError).status).toBe(409);
    expect((conflict as SyncError).code).toBe("send_idempotency_conflict");

    const poll = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      poll: { question: "Pick", options: ["A", "B"], anonymous: false },
      pollsEnabled: true,
    });
    await expect(sendMessage(db, {
      senderAccountId: bob.accountId,
      senderDeviceId: bob.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      forwardedFrom: { dialogId, msgId: poll.msgId },
      pollsEnabled: false,
    })).rejects.toMatchObject({ status: 404, code: "capability_unavailable" });
    const forwarded = await sendMessage(db, {
      senderAccountId: bob.accountId,
      senderDeviceId: bob.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      forwardedFrom: { dialogId, msgId: poll.msgId },
      pollsEnabled: true,
    });
    const forwardedPoll = (await getHistory(db, bob.accountId, dialogId)).messages
      .find((message) => message.msg_id === forwarded.msgId)?.poll;
    expect(forwardedPoll?.total_voters).toBeUndefined();
    expect(forwardedPoll?.my_option_indices).toEqual([]);
    expect(await db`
      SELECT count(*)::int AS count FROM poll_votes
      WHERE dialog_id = ${dialogId} AND msg_id = ${forwarded.msgId}`)
      .toEqual([expect.objectContaining({ count: 0 })]);
  });

  test("poll privacy, mutable votes, quiz locking, closure, and independent forwards hold", async () => {
    const { alice, bob, dialogId } = await pair();
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      poll: {
        question: "Tea?",
        options: ["Green", "Black", "None"],
        multipleChoice: true,
        anonymous: false,
      },
      pollsEnabled: true,
    });
    const before = (await getHistory(db, bob.accountId, dialogId)).messages
      .find((message) => message.msg_id === sent.msgId)?.poll;
    expect(before?.total_voters).toBeUndefined();
    expect(before?.options.every((option) => option.votes === undefined)).toBe(true);

    const firstVote = await voteInPoll(db, {
      ...mutation(bob), dialogId, msgId: sent.msgId, optionIndices: [0, 1],
    });
    expect(firstVote.poll.total_voters).toBe(1);
    expect(firstVote.poll.my_option_indices).toEqual([0, 1]);
    const secondVote = await voteInPoll(db, {
      ...mutation(bob), dialogId, msgId: sent.msgId, optionIndices: [2],
    });
    expect(secondVote.poll.total_voters).toBe(1);
    expect(secondVote.poll.my_option_indices).toEqual([2]);
    const voters = await listPollVoters(db, alice.accountId, dialogId, sent.msgId);
    expect(voters.items.map((item) => item.account_id)).toEqual([bob.accountId]);

    await closePoll(db, { ...mutation(alice), dialogId, msgId: sent.msgId });
    await expect(voteInPoll(db, {
      ...mutation(bob), dialogId, msgId: sent.msgId, optionIndices: [],
    })).rejects.toMatchObject({ status: 409, code: "poll_closed" });

    const anonymous = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      poll: { question: "Private?", options: ["Yes", "No"] },
      pollsEnabled: true,
    });
    await expect(listPollVoters(db, bob.accountId, dialogId, anonymous.msgId))
      .rejects.toMatchObject({ status: 403, code: "anonymous_poll" });

    const quiz = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      poll: {
        question: "2 + 2?",
        options: ["3", "4"],
        quiz: true,
        correctOptionIndex: 1,
        explanation: "Basic arithmetic",
      },
      pollsEnabled: true,
    });
    const answer = await voteInPoll(db, {
      ...mutation(bob), dialogId, msgId: quiz.msgId, optionIndices: [0],
    });
    expect(answer.poll.correct_option_index).toBe(1);
    expect(answer.poll.explanation).toBe("Basic arithmetic");
    await expect(voteInPoll(db, {
      ...mutation(bob), dialogId, msgId: quiz.msgId, optionIndices: [1],
    })).rejects.toMatchObject({ status: 409, code: "quiz_vote_locked" });
  });

  test("expired messages are hidden immediately and cleanup atomically removes derived state", async () => {
    const { alice, bob, dialogId } = await pair();
    await setDialogAutoDelete(db, {
      ...mutation(alice), dialogId, seconds: 3_600,
    });
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      poll: { question: "Temporary", options: ["A", "B"], anonymous: false },
      pollsEnabled: true,
    });
    const stamped = (await db`
      SELECT expires_at FROM messages WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0];
    expect(stamped.expires_at).not.toBeNull();

    const pinOperationId = crypto.randomUUID();
    const pin = await mutatePinnedMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      operationId: pinOperationId,
      dialogId,
      msgId: sent.msgId,
      pinned: true,
      notifyMembers: false,
    });
    expect(pin.pin_count).toBe(1);
    expect(Number((await db`
      SELECT count(*) AS count FROM messages
      WHERE dialog_id = ${dialogId} AND kind = 'service'`)[0].count)).toBe(1);
    const duplicate = await mutatePinnedMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      operationId: pinOperationId,
      dialogId,
      msgId: sent.msgId,
      pinned: true,
      notifyMembers: false,
    });
    expect(duplicate.duplicate).toBe(true);
    await expect(mutatePinnedMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      operationId: pinOperationId,
      dialogId,
      msgId: sent.msgId,
      pinned: false,
      notifyMembers: false,
    })).rejects.toMatchObject({ status: 409, code: "idempotency_conflict" });

    await voteInPoll(db, {
      ...mutation(bob), dialogId, msgId: sent.msgId, optionIndices: [1],
    });
    await db`
      UPDATE messages SET expires_at = now() - interval '1 second'
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`;
    expect((await getHistory(db, bob.accountId, dialogId)).messages
      .some((message) => message.msg_id === sent.msgId)).toBe(false);
    expect((await listPinnedMessages(db, alice.accountId, dialogId)).count).toBe(0);
    await expect(voteInPoll(db, {
      ...mutation(bob), dialogId, msgId: sent.msgId, optionIndices: [],
    })).rejects.toMatchObject({ status: 409, code: "poll_unavailable" });

    expect(await expireAcceptedMessages(db)).toMatchObject({ expired: 1 });
    expect((await db`
      SELECT state, body_ciphertext, media_id FROM messages
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0])
      .toEqual(expect.objectContaining({ state: "deleted_for_all", media_id: null }));
    expect(Number((await db`
      SELECT count(*) AS count FROM message_pins
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0].count)).toBe(0);
    expect(Number((await db`
      SELECT count(*) AS count FROM message_polls
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0].count)).toBe(0);
    expect(Number((await db`
      SELECT count(*) AS count FROM poll_votes
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0].count)).toBe(0);
  });

  test("stickers remain referentially stable and GIPHY stores provider references only", async () => {
    const { alice, dialogId } = await pair();
    await db`
      INSERT INTO sticker_packs(id, version, title, manifest_sha256)
      VALUES ('toj.core', 1, 'Toj Core', ${Buffer.alloc(32, 0x11)})`;
    await db`
      INSERT INTO stickers(
        id, pack_id, pack_version, format, mime_type, byte_size,
        width, height, sha256, asset_url, emoji, tags
      ) VALUES (
        'toj.core.wave', 'toj.core', 1, 'png', 'image/png', 1024,
        256, 256, ${Buffer.alloc(32, 0x22)},
        'https://cdn.example.invalid/toj.core.wave.png',
        ARRAY['👋'], ARRAY['wave','hello']
      )`;
    const catalog = await getStickerCatalog(db, alice.accountId, { query: "wave" });
    expect(catalog.stickers.map((sticker) => sticker.id)).toEqual(["toj.core.wave"]);

    const stickerMessage = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      stickerId: "toj.core.wave",
      stickersEnabled: true,
    });
    let sticker = (await getHistory(db, alice.accountId, dialogId)).messages
      .find((message) => message.msg_id === stickerMessage.msgId)?.sticker;
    expect(sticker).toMatchObject({
      id: "toj.core.wave",
      pack_id: "toj.core",
      pack_version: 1,
      unavailable: false,
    });
    await db`UPDATE stickers SET status = 'withdrawn' WHERE id = 'toj.core.wave'`;
    sticker = (await getHistory(db, alice.accountId, dialogId)).messages
      .find((message) => message.msg_id === stickerMessage.msgId)?.sticker;
    expect(sticker).toMatchObject({ id: "toj.core.wave", unavailable: true });
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      stickerId: "toj.core.wave",
      stickersEnabled: true,
    })).rejects.toMatchObject({ status: 409, code: "sticker_unavailable" });

    const giphyMessage = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      giphyReference: {
        providerId: "gif_abc-123",
        rendition: {
          width: 320,
          height: 180,
          url: "https://media.example.invalid/never-store-this.gif",
        },
        accountId: alice.accountId,
        searchTerm: "private words",
      },
      giphyEnabled: true,
    });
    const stored = (await db`
      SELECT provider, provider_item_id, rendition
      FROM message_external_content
      WHERE dialog_id = ${dialogId} AND msg_id = ${giphyMessage.msgId}`)[0];
    const storedRendition = typeof stored.rendition === "string"
      ? JSON.parse(stored.rendition)
      : stored.rendition;
    expect({ ...stored, rendition: storedRendition }).toMatchObject({
      provider: "giphy",
      provider_item_id: "gif_abc-123",
      rendition: { width: 320, height: 180 },
    });
    expect(JSON.stringify(stored)).not.toContain("never-store-this");
    expect(JSON.stringify(stored)).not.toContain("private words");
    expect(JSON.stringify(stored)).not.toContain(alice.accountId);
    const external = (await getHistory(db, alice.accountId, dialogId)).messages
      .find((message) => message.msg_id === giphyMessage.msgId)?.external_media;
    expect(external).toMatchObject({ provider: "giphy", provider_id: "gif_abc-123" });
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      giphyReference: { providerId: "https://not-an-id.invalid/a.gif" },
      giphyEnabled: true,
    })).rejects.toMatchObject({ code: "invalid_message_content" });

    const disabledConfig = giphyClientConfiguration({
      pinnedMessages: false,
      autoDeleteCreation: false,
      polls: false,
      stickerPacks: false,
      giphy: false,
      multiAccountPush: false,
      support: false,
    });
    expect(disabledConfig).toEqual({
      enabled: false,
      rating: "pg",
      attribution_required: true,
      proxying_permitted: false,
      persistence: "provider_id_only",
    });
  });

  test("one installation routes three accounts, fences a fourth, and preserves rotated tokens", async () => {
    const accounts = [];
    for (let index = 0; index < 4; index += 1) {
      accounts.push(await account(`+1650555620${index}`, `Account ${index}`));
    }
    const installationId = crypto.randomUUID();
    const token = "aa".repeat(32);
    const handles: string[] = [];
    for (const value of accounts.slice(0, 3)) {
      const registration = await registerInstallationPushToken(db, {
        accountId: value.accountId,
        deviceId: value.deviceId,
        installationId,
        token,
        environment: "sandbox",
        kind: "normal",
      });
      handles.push(registration.routingHandle);
    }
    expect(new Set(handles).size).toBe(3);
    const repeated = await registerInstallationPushToken(db, {
      accountId: accounts[0].accountId,
      deviceId: accounts[0].deviceId,
      installationId,
      token,
      environment: "sandbox",
      kind: "normal",
    });
    expect(repeated.routingHandle).toBe(handles[0]);
    await expect(registerInstallationPushToken(db, {
      accountId: accounts[3].accountId,
      deviceId: accounts[3].deviceId,
      installationId,
      token,
      environment: "sandbox",
      kind: "normal",
    })).rejects.toBeInstanceOf(PushError);
    expect(Number((await db`
      SELECT count(*) AS count FROM push_account_bindings
      WHERE installation_id = ${installationId} AND active`)[0].count)).toBe(3);

    await registerInstallationVoIPPushToken(db, {
      accountId: accounts[0].accountId,
      deviceId: accounts[0].deviceId,
      installationId,
      token: "bb".repeat(32),
      environment: "sandbox",
    });
    await unregisterInstallationTokenKind(
      db,
      accounts[0].accountId,
      accounts[0].deviceId,
      installationId,
      "normal",
    );
    expect((await db`
      SELECT active, normal_enabled, voip_enabled FROM push_account_bindings
      WHERE installation_id = ${installationId} AND account_id = ${accounts[0].accountId}`)[0])
      .toEqual(expect.objectContaining({ active: true, normal_enabled: false, voip_enabled: true }));

    const opaque = buildVoIPAPNsPayload({
      callId: crypto.randomUUID(),
      callerAccountId: accounts[3].accountId,
      initialKind: "voice",
      expiresAt: new Date(Date.now() + 30_000).toISOString(),
      routingHandle: handles[0],
    });
    expect((opaque.toj as any).routingHandle).toBe(handles[0]);
    expect((opaque.toj as any).callerAccountId).toBeUndefined();

    await resetDb();
    const { alice, bob, dialogId } = await pair();
    const bobInstallationId = crypto.randomUUID();
    await registerInstallationPushToken(db, {
      accountId: bob.accountId,
      deviceId: bob.deviceId,
      installationId: bobInstallationId,
      token: "cc".repeat(32),
      environment: "sandbox",
      kind: "normal",
    });
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "push race",
    });
    const sender = new RotatingSender(async () => {
      await registerInstallationPushToken(db, {
        accountId: bob.accountId,
        deviceId: bob.deviceId,
        installationId: bobInstallationId,
        token: "dd".repeat(32),
        environment: "sandbox",
        kind: "normal",
      });
    });
    expect(await processPushBatch(db, sender)).toBeGreaterThan(0);
    expect(sender.requests.some((request) => request.token === "cc".repeat(32))).toBe(true);
    expect((await db`
      SELECT installation.normal_token_hash IS NOT NULL AS token_present,
             binding.active, binding.normal_enabled
      FROM push_installations installation
      JOIN push_account_bindings binding USING (installation_id)
      WHERE installation.installation_id = ${bobInstallationId}
        AND binding.account_id = ${bob.accountId}`)[0])
      .toEqual(expect.objectContaining({ token_present: true, active: true, normal_enabled: true }));
  });

  test("revoking a device removes only its shared installation binding and frees the account slot", async () => {
    const accounts = [];
    for (let index = 0; index < 4; index += 1) {
      accounts.push(await account(`+1650555621${index}`, `Binding ${index}`));
    }
    const installationId = crypto.randomUUID();
    const token = "ef".repeat(32);
    for (const value of accounts.slice(0, 3)) {
      await registerInstallationPushToken(db, {
        accountId: value.accountId,
        deviceId: value.deviceId,
        installationId,
        token,
        environment: "sandbox",
        kind: "normal",
      });
    }

    await revokeDevice(db, accounts[0].accountId, accounts[0].deviceId);
    await registerInstallationPushToken(db, {
      accountId: accounts[3].accountId,
      deviceId: accounts[3].deviceId,
      installationId,
      token,
      environment: "sandbox",
      kind: "normal",
    });

    const bindings = await db`SELECT account_id, active, normal_enabled
      FROM push_account_bindings WHERE installation_id = ${installationId}
      ORDER BY account_id`;
    expect(bindings).toHaveLength(3);
    expect(bindings.some((row: any) => String(row.account_id) === accounts[0].accountId)).toBe(false);
    expect(bindings.every((row: any) => row.active && row.normal_enabled)).toBe(true);
    expect((await db`SELECT normal_token_hash IS NOT NULL AS token_present
      FROM push_installations WHERE installation_id = ${installationId}`)[0].token_present).toBe(true);
  });
});
