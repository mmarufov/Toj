import type { SQL } from "bun";
import { bodyAAD } from "./crypto";
import { sealForScope } from "./envelope-crypto";
import { fanoutDialogEvent, type FanoutPush } from "./fanout";
import { notifySyncWakeups } from "./sync-wakeup";

export type MessageExpiryCleanup = {
  expired: number;
  mediaRemoved: number;
  pushes: FanoutPush[];
};

/**
 * Enforces already-stamped expiries independently of the feature creation gate. Candidate
 * discovery is lock-free; each item is then linearized through dialog -> message locks so cleanup
 * cannot race an edit, delete, pin, vote, or membership mutation in the opposite lock order.
 */
export async function expireAcceptedMessages(
  sql: SQL,
  batchSize = 100,
): Promise<MessageExpiryCleanup> {
  const boundedBatch = Math.max(1, Math.min(1_000, Number(batchSize)));
  const candidates = await sql`
    SELECT dialog_id, msg_id
    FROM messages
    WHERE state = 'visible' AND expires_at IS NOT NULL AND expires_at <= now()
    ORDER BY expires_at, dialog_id, msg_id
    LIMIT ${boundedBatch}`;
  let expired = 0;
  let mediaRemoved = 0;
  const pushes: FanoutPush[] = [];
  for (const candidate of candidates) {
    const result = await sql.begin(async (tx) => {
      const dialog = (await tx`
        SELECT id FROM dialogs WHERE id = ${candidate.dialog_id} FOR UPDATE`)[0];
      if (!dialog) return null;
      const message = (await tx`
        SELECT sender_account_id, media_id
        FROM messages
        WHERE dialog_id = ${candidate.dialog_id} AND msg_id = ${candidate.msg_id}
          AND state = 'visible' AND expires_at IS NOT NULL AND expires_at <= now()
        FOR UPDATE`)[0];
      if (!message) return null;

      const dialogId = String(candidate.dialog_id);
      const msgId = Number(candidate.msg_id);
      const senderAccountId = String(message.sender_account_id);
      const sealed = await sealForScope(
        tx,
        { kind: "account", accountId: senderAccountId },
        "",
        bodyAAD(dialogId, msgId, senderAccountId),
      );

      // Delete all derived live data before publishing the tombstone. Poll votes cascade from the
      // encrypted poll row; pins and reactions disappear atomically with visibility.
      await tx`DELETE FROM message_pins WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`;
      await tx`DELETE FROM message_reactions WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`;
      await tx`DELETE FROM message_mentions WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`;
      await tx`DELETE FROM message_polls WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`;
      await tx`DELETE FROM message_external_content WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`;
      await tx`DELETE FROM link_preview_waiters WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`;
      await tx`DELETE FROM message_link_previews WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`;
      await tx`
        UPDATE messages
        SET body_key_id = ${sealed.keyId}, body_nonce = ${sealed.nonce},
            body_ciphertext = ${sealed.ciphertext}, media_id = NULL,
            state = 'deleted_for_all', deleted_at = now()
        WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`;

      let removedMedia = 0;
      if (message.media_id) {
        const deleted = await tx`
          DELETE FROM media_objects media
          WHERE media.id = ${message.media_id}
            AND NOT EXISTS (SELECT 1 FROM messages other WHERE other.media_id = media.id)
            AND NOT EXISTS (SELECT 1 FROM dialogs other WHERE other.photo_media_id = media.id)
            AND NOT EXISTS (
              SELECT 1
              FROM scheduled_delivery_items item
              JOIN scheduled_deliveries delivery ON delivery.id = item.delivery_id
              WHERE item.media_id = media.id AND delivery.state IN ('scheduled','processing')
            )
            AND NOT EXISTS (
              SELECT 1
              FROM draft_attachments attachment
              JOIN account_dialog_drafts draft
                ON draft.account_id = attachment.account_id
               AND draft.dialog_id = attachment.dialog_id
              WHERE attachment.media_id = media.id AND draft.state = 'active'
            )
          RETURNING media.id`;
        removedMedia = deleted.length;
      }

      const eventPushes = await fanoutDialogEvent(tx, {
        dialogId,
        type: "message.expired",
        msgId,
        actorAccountId: senderAccountId,
        alertRecipients: false,
        data: { reason: "expired" },
      });
      await notifySyncWakeups(tx, eventPushes);
      return { removedMedia, pushes: eventPushes };
    });
    if (!result) continue;
    expired += 1;
    mediaRemoved += result.removedMedia;
    pushes.push(...result.pushes);
  }
  return { expired, mediaRemoved, pushes };
}

export async function expiredMessageBacklog(sql: SQL): Promise<number> {
  return Number((await sql`
    SELECT count(*) AS count FROM messages
    WHERE state = 'visible' AND expires_at IS NOT NULL AND expires_at <= now()`)[0].count);
}
