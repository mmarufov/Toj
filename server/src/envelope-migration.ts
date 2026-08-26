import type { SQL } from "bun";
import {
  bodyAAD,
  draftBodyAAD,
  draftResponseAAD,
  chatFolderTitleAAD,
  linkPreviewAssetAAD,
  linkPreviewMetadataAAD,
  linkPreviewURLAAD,
  mediaChunkAAD,
  mediaFileNameAAD,
  mediaThumbnailAAD,
  installationPushTokenAAD,
  pollAAD,
  PHONE_AAD,
  pushTokenAAD,
  reportActionNoteAAD,
  reportEvidenceAAD,
  scheduledItemAAD,
  sessionRotationAAD,
  voipPushTokenAAD,
} from "./crypto";
import {
  openForScope,
  sealForScope,
  tryLockEnvelopeScopeForMigration,
  type KeyScope,
} from "./envelope-crypto";

export const ENVELOPE_MIGRATION_DOMAINS = [
  "phone-identity",
  "messages",
  "message-polls",
  "drafts",
  "draft-responses",
  "push-tokens",
  "installation-push-tokens",
  "session-rotation-receipts",
  "media-metadata",
  "media-chunks",
  "moderation-evidence",
  "moderation-notes",
  "chat-folder-titles",
  "scheduled-items",
  "link-preview-cache",
  "link-preview-messages",
  "link-preview-snapshots",
  "link-preview-assets",
] as const;

export type EnvelopeMigrationDomain = typeof ENVELOPE_MIGRATION_DOMAINS[number];
type MigrationResult = {
  domain: EnvelopeMigrationDomain;
  migrated: number;
  remaining: number;
  retryable: boolean;
};
type MigrationBatchResult = { migrated: number; contended: boolean };

const MIGRATION_INDEXES: Record<EnvelopeMigrationDomain, string[]> = {
  "phone-identity": ["accounts_phone_key_migration_idx"],
  messages: ["messages_body_key_migration_idx"],
  "message-polls": ["message_polls_payload_key_migration_idx"],
  drafts: ["drafts_body_key_migration_idx"],
  "draft-responses": ["draft_responses_key_migration_idx"],
  "push-tokens": ["devices_push_key_migration_idx", "devices_voip_key_migration_idx"],
  "installation-push-tokens": [
    "push_installations_normal_key_migration_idx",
    "push_installations_voip_key_migration_idx",
  ],
  "session-rotation-receipts": ["session_rotation_receipts_key_migration_idx"],
  "media-metadata": ["media_file_name_key_migration_idx", "media_thumbnail_key_migration_idx"],
  "media-chunks": ["media_chunks_key_migration_idx"],
  "moderation-evidence": ["abuse_reports_evidence_key_migration_idx"],
  "moderation-notes": ["abuse_report_notes_key_migration_idx"],
  "chat-folder-titles": ["chat_folders_title_key_migration_idx"],
  "scheduled-items": ["scheduled_items_payload_key_migration_idx"],
  "link-preview-cache": ["link_preview_cache_key_migration_idx"],
  "link-preview-messages": ["message_link_preview_key_migration_idx"],
  "link-preview-snapshots": [
    "link_preview_snapshot_url_key_migration_idx",
    "link_preview_snapshot_metadata_key_migration_idx",
  ],
  "link-preview-assets": ["link_preview_assets_key_migration_idx"],
};

const buf = (value: Uint8Array) => Buffer.from(value);
const n = (value: unknown) => Number(value as any);

async function reseal(
  sql: SQL,
  scope: KeyScope,
  row: { key_id: string; nonce: Uint8Array; ciphertext: Uint8Array },
  aad: Buffer,
) {
  // Writers may have taken this scope fence before waiting for the row we already own. Never
  // block in the inverse order: skip the row, commit this bounded batch, and let the caller retry.
  if (!await tryLockEnvelopeScopeForMigration(sql, scope)) return null;
  const plaintext = await openForScope(sql, scope, {
    keyId: row.key_id,
    nonce: buf(row.nonce),
    ciphertext: buf(row.ciphertext),
  }, aad, true);
  try {
    // The transaction now owns the scope fence, so its active key can be safely reused.
    return await sealForScope(sql, scope, plaintext, aad, true, true);
  } finally {
    plaintext.fill(0);
  }
}

async function migrationBatch(
  sql: SQL,
  scopes: KeyScope[],
  migrate: () => Promise<number>,
): Promise<MigrationBatchResult> {
  const unique = new Map(scopes.map((scope) => [
    scope.kind === "account" ? `account:${scope.accountId}` : `service:${scope.serviceName}`,
    scope,
  ]));
  // Advisory locks are retained until commit. Acquire every scope in one deterministic order so
  // two heterogeneous batches cannot deadlock with each other; try-locking also lets a writer that
  // already owns the inverse row/key order finish before the next bounded retry.
  for (const scope of [...unique.entries()].sort(([left], [right]) => left.localeCompare(right))
    .map(([, scope]) => scope)) {
    if (!await tryLockEnvelopeScopeForMigration(sql, scope)) {
      return { migrated: 0, contended: true };
    }
  }
  return { migrated: await migrate(), contended: false };
}

async function migratePhoneIdentity(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT id, phone_key_id AS key_id, phone_nonce AS nonce,
           phone_e164_ciphertext AS ciphertext
    FROM accounts WHERE phone_key_id = ${fromKeyId}
    ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      const sealed = await reseal(sql, { kind: "account", accountId: row.id }, row as any, PHONE_AAD);
      if (!sealed) continue;
      const updated = await sql`UPDATE accounts SET phone_key_id = ${sealed.keyId}, phone_nonce = ${sealed.nonce},
        phone_e164_ciphertext = ${sealed.ciphertext}
        WHERE id = ${row.id} AND phone_key_id = ${fromKeyId} RETURNING id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateMessages(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT dialog_id, msg_id, sender_account_id, body_key_id AS key_id,
           body_nonce AS nonce, body_ciphertext AS ciphertext
    FROM messages WHERE body_key_id = ${fromKeyId}
    ORDER BY dialog_id, msg_id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.sender_account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      const aad = bodyAAD(row.dialog_id, row.msg_id, row.sender_account_id);
      const sealed = await reseal(
        sql, { kind: "account", accountId: row.sender_account_id }, row as any, aad,
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE messages SET body_key_id = ${sealed.keyId}, body_nonce = ${sealed.nonce},
        body_ciphertext = ${sealed.ciphertext}
        WHERE dialog_id = ${row.dialog_id} AND msg_id = ${row.msg_id}
          AND body_key_id = ${fromKeyId} RETURNING msg_id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateMessagePolls(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT poll.dialog_id, poll.msg_id, poll.payload_key_id AS key_id,
           poll.payload_nonce AS nonce, poll.payload_ciphertext AS ciphertext,
           message.sender_account_id
    FROM message_polls poll
    JOIN messages message
      ON message.dialog_id = poll.dialog_id AND message.msg_id = poll.msg_id
    WHERE poll.payload_key_id = ${fromKeyId}
    ORDER BY poll.dialog_id, poll.msg_id
    FOR UPDATE OF poll SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.sender_account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      const sealed = await reseal(
        sql,
        { kind: "account", accountId: String(row.sender_account_id) },
        row as any,
        pollAAD(String(row.dialog_id), n(row.msg_id)),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE message_polls
        SET payload_key_id = ${sealed.keyId}, payload_nonce = ${sealed.nonce},
            payload_ciphertext = ${sealed.ciphertext}
        WHERE dialog_id = ${row.dialog_id} AND msg_id = ${row.msg_id}
          AND payload_key_id = ${fromKeyId} RETURNING msg_id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateDrafts(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT account_id, dialog_id, revision, body_key_id AS key_id,
           body_nonce AS nonce, body_ciphertext AS ciphertext
    FROM account_dialog_drafts WHERE body_key_id = ${fromKeyId}
    ORDER BY account_id, dialog_id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      const aad = draftBodyAAD(row.account_id, row.dialog_id, row.revision);
      const sealed = await reseal(sql, { kind: "account", accountId: row.account_id }, row as any, aad);
      if (!sealed) continue;
      const updated = await sql`UPDATE account_dialog_drafts
        SET body_key_id = ${sealed.keyId}, body_nonce = ${sealed.nonce},
            body_ciphertext = ${sealed.ciphertext}
        WHERE account_id = ${row.account_id} AND dialog_id = ${row.dialog_id}
          AND body_key_id = ${fromKeyId} RETURNING dialog_id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateDraftResponses(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT account_id, operation_id, response_key_id AS key_id,
           response_nonce AS nonce, response_ciphertext AS ciphertext
    FROM draft_mutation_requests WHERE response_key_id = ${fromKeyId}
    ORDER BY account_id, operation_id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      const aad = draftResponseAAD(row.account_id, row.operation_id);
      const sealed = await reseal(sql, { kind: "account", accountId: row.account_id }, row as any, aad);
      if (!sealed) continue;
      const updated = await sql`UPDATE draft_mutation_requests
        SET response_key_id = ${sealed.keyId}, response_nonce = ${sealed.nonce},
            response_ciphertext = ${sealed.ciphertext}
        WHERE account_id = ${row.account_id} AND operation_id = ${row.operation_id}
          AND response_key_id = ${fromKeyId} RETURNING operation_id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migratePushTokens(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT id, account_id, push_token_key_id, push_token_nonce, push_token_ciphertext,
           voip_push_token_key_id, voip_push_token_nonce, voip_push_token_ciphertext
    FROM devices
    WHERE push_token_key_id = ${fromKeyId} OR voip_push_token_key_id = ${fromKeyId}
    ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      let touched = false;
      if (row.push_token_key_id === fromKeyId) {
        if (!row.push_token_nonce || !row.push_token_ciphertext) {
          throw new Error(`device ${row.id} has an incomplete push-token ciphertext tuple`);
        }
        const sealed = await reseal(sql, { kind: "account", accountId: row.account_id }, {
          key_id: row.push_token_key_id,
          nonce: row.push_token_nonce,
          ciphertext: row.push_token_ciphertext,
        }, pushTokenAAD(row.id));
        if (sealed) {
          const updated = await sql`UPDATE devices SET push_token_key_id = ${sealed.keyId},
            push_token_nonce = ${sealed.nonce}, push_token_ciphertext = ${sealed.ciphertext}
            WHERE id = ${row.id} AND push_token_key_id = ${fromKeyId} RETURNING id`;
          touched ||= updated.length > 0;
        }
      }
      if (row.voip_push_token_key_id === fromKeyId) {
        if (!row.voip_push_token_nonce || !row.voip_push_token_ciphertext) {
          throw new Error(`device ${row.id} has an incomplete VoIP-token ciphertext tuple`);
        }
        const sealed = await reseal(sql, { kind: "account", accountId: row.account_id }, {
          key_id: row.voip_push_token_key_id,
          nonce: row.voip_push_token_nonce,
          ciphertext: row.voip_push_token_ciphertext,
        }, voipPushTokenAAD(row.id));
        if (sealed) {
          const updated = await sql`UPDATE devices SET voip_push_token_key_id = ${sealed.keyId},
            voip_push_token_nonce = ${sealed.nonce}, voip_push_token_ciphertext = ${sealed.ciphertext}
            WHERE id = ${row.id} AND voip_push_token_key_id = ${fromKeyId} RETURNING id`;
          touched ||= updated.length > 0;
        }
      }
      if (touched) migrated += 1;
    }
    return migrated;
  });
}

async function migrateInstallationPushTokens(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT installation_id,
           normal_token_key_id, normal_token_nonce, normal_token_ciphertext,
           voip_token_key_id, voip_token_nonce, voip_token_ciphertext
    FROM push_installations
    WHERE normal_token_key_id = ${fromKeyId} OR voip_token_key_id = ${fromKeyId}
    ORDER BY installation_id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  const scope: KeyScope = { kind: "service", serviceName: "push-installation" };
  return migrationBatch(sql, [scope], async () => {
    let migrated = 0;
    for (const row of rows) {
      let touched = false;
      if (row.normal_token_key_id === fromKeyId) {
        if (!row.normal_token_nonce || !row.normal_token_ciphertext) {
          throw new Error(`installation ${row.installation_id} has an incomplete push-token ciphertext tuple`);
        }
        const sealed = await reseal(sql, scope, {
          key_id: row.normal_token_key_id,
          nonce: row.normal_token_nonce,
          ciphertext: row.normal_token_ciphertext,
        }, installationPushTokenAAD(String(row.installation_id), "normal"));
        if (sealed) {
          const updated = await sql`UPDATE push_installations
            SET normal_token_key_id = ${sealed.keyId}, normal_token_nonce = ${sealed.nonce},
                normal_token_ciphertext = ${sealed.ciphertext}
            WHERE installation_id = ${row.installation_id}
              AND normal_token_key_id = ${fromKeyId} RETURNING installation_id`;
          touched ||= updated.length > 0;
        }
      }
      if (row.voip_token_key_id === fromKeyId) {
        if (!row.voip_token_nonce || !row.voip_token_ciphertext) {
          throw new Error(`installation ${row.installation_id} has an incomplete VoIP-token ciphertext tuple`);
        }
        const sealed = await reseal(sql, scope, {
          key_id: row.voip_token_key_id,
          nonce: row.voip_token_nonce,
          ciphertext: row.voip_token_ciphertext,
        }, installationPushTokenAAD(String(row.installation_id), "voip"));
        if (sealed) {
          const updated = await sql`UPDATE push_installations
            SET voip_token_key_id = ${sealed.keyId}, voip_token_nonce = ${sealed.nonce},
                voip_token_ciphertext = ${sealed.ciphertext}
            WHERE installation_id = ${row.installation_id}
              AND voip_token_key_id = ${fromKeyId} RETURNING installation_id`;
          touched ||= updated.length > 0;
        }
      }
      if (touched) migrated += 1;
    }
    return migrated;
  });
}

async function migrateSessionRotationReceipts(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT receipt.session_id, receipt.rotation_id,
           receipt.response_key_id AS key_id, receipt.response_nonce AS nonce,
           receipt.response_ciphertext AS ciphertext, device.account_id
    FROM session_rotation_receipts receipt
    JOIN device_sessions session ON session.id = receipt.session_id
    JOIN devices device ON device.id = session.device_id
    WHERE receipt.response_key_id = ${fromKeyId}
    ORDER BY receipt.session_id, receipt.rotation_id
    FOR UPDATE OF receipt SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      const sealed = await reseal(
        sql,
        { kind: "account", accountId: String(row.account_id) },
        row as any,
        sessionRotationAAD(String(row.session_id), String(row.rotation_id)),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE session_rotation_receipts
        SET response_key_id = ${sealed.keyId}, response_nonce = ${sealed.nonce},
            response_ciphertext = ${sealed.ciphertext}
        WHERE session_id = ${row.session_id} AND rotation_id = ${row.rotation_id}
          AND response_key_id = ${fromKeyId} RETURNING rotation_id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateMediaMetadata(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT id, owner_account_id, file_name_key_id, file_name_nonce, file_name_ciphertext,
           thumbnail_key_id, thumbnail_nonce, thumbnail_ciphertext
    FROM media_objects
    WHERE file_name_key_id = ${fromKeyId} OR thumbnail_key_id = ${fromKeyId}
    ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.owner_account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      let touched = false;
      const scope: KeyScope = { kind: "account", accountId: row.owner_account_id };
      if (row.file_name_key_id === fromKeyId) {
        if (!row.file_name_nonce || !row.file_name_ciphertext) {
          throw new Error(`media object ${row.id} has an incomplete file-name ciphertext tuple`);
        }
        const sealed = await reseal(sql, scope, {
          key_id: row.file_name_key_id,
          nonce: row.file_name_nonce,
          ciphertext: row.file_name_ciphertext,
        }, mediaFileNameAAD(row.id));
        if (sealed) {
          const updated = await sql`UPDATE media_objects SET file_name_key_id = ${sealed.keyId},
            file_name_nonce = ${sealed.nonce}, file_name_ciphertext = ${sealed.ciphertext}
            WHERE id = ${row.id} AND file_name_key_id = ${fromKeyId} RETURNING id`;
          touched ||= updated.length > 0;
        }
      }
      if (row.thumbnail_key_id === fromKeyId) {
        if (!row.thumbnail_nonce || !row.thumbnail_ciphertext) {
          throw new Error(`media object ${row.id} has an incomplete thumbnail ciphertext tuple`);
        }
        const sealed = await reseal(sql, scope, {
          key_id: row.thumbnail_key_id,
          nonce: row.thumbnail_nonce,
          ciphertext: row.thumbnail_ciphertext,
        }, mediaThumbnailAAD(row.id));
        if (sealed) {
          const updated = await sql`UPDATE media_objects SET thumbnail_key_id = ${sealed.keyId},
            thumbnail_nonce = ${sealed.nonce}, thumbnail_ciphertext = ${sealed.ciphertext}
            WHERE id = ${row.id} AND thumbnail_key_id = ${fromKeyId} RETURNING id`;
          touched ||= updated.length > 0;
        }
      }
      if (touched) migrated += 1;
    }
    return migrated;
  });
}

async function migrateMediaChunks(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT chunk.media_id, chunk.chunk_offset, chunk.key_id, chunk.nonce, chunk.ciphertext,
           media.owner_account_id
    FROM media_chunks chunk JOIN media_objects media ON media.id = chunk.media_id
    WHERE chunk.key_id = ${fromKeyId}
    ORDER BY chunk.media_id, chunk.chunk_offset
    FOR UPDATE OF chunk SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.owner_account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      const sealed = await reseal(
        sql,
        { kind: "account", accountId: row.owner_account_id },
        row as any,
        mediaChunkAAD(row.media_id, row.chunk_offset),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE media_chunks SET key_id = ${sealed.keyId}, nonce = ${sealed.nonce},
        ciphertext = ${sealed.ciphertext}
        WHERE media_id = ${row.media_id} AND chunk_offset = ${row.chunk_offset}
          AND key_id = ${fromKeyId} RETURNING media_id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateModerationEvidence(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT id, reporter_account_id, evidence_key_id AS key_id,
           evidence_nonce AS nonce, evidence_ciphertext AS ciphertext
    FROM abuse_reports WHERE evidence_key_id = ${fromKeyId}
    ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, [{ kind: "service", serviceName: "moderation-evidence" }], async () => {
    let migrated = 0;
    for (const row of rows) {
      const sealed = await reseal(
        sql,
        { kind: "service", serviceName: "moderation-evidence" },
        row as any,
        reportEvidenceAAD(row.id, row.reporter_account_id),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE abuse_reports SET evidence_key_id = ${sealed.keyId},
        evidence_nonce = ${sealed.nonce}, evidence_ciphertext = ${sealed.ciphertext}
        WHERE id = ${row.id} AND evidence_key_id = ${fromKeyId} RETURNING id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateModerationNotes(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  await sql`SELECT set_config('toj.allow_abuse_report_crypto_migration', '1', TRUE)`;
  const rows = await sql`
    SELECT id, report_id, action, actor_id, note_key_id AS key_id,
           note_nonce AS nonce, note_ciphertext AS ciphertext
    FROM abuse_report_actions WHERE note_key_id = ${fromKeyId}
    ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, [{ kind: "service", serviceName: "moderation-evidence" }], async () => {
    let migrated = 0;
    for (const row of rows) {
      const sealed = await reseal(
        sql,
        { kind: "service", serviceName: "moderation-evidence" },
        row as any,
        reportActionNoteAAD(row.report_id, row.action, row.actor_id ?? "system"),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE abuse_report_actions SET note_key_id = ${sealed.keyId},
        note_nonce = ${sealed.nonce}, note_ciphertext = ${sealed.ciphertext}
        WHERE id = ${row.id} AND note_key_id = ${fromKeyId} RETURNING id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateChatFolderTitles(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT account_id, folder_id, title_key_id AS key_id, title_nonce AS nonce,
           title_ciphertext AS ciphertext
    FROM chat_folders WHERE title_key_id = ${fromKeyId}
    ORDER BY account_id, folder_id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      const sealed = await reseal(
        sql,
        { kind: "account", accountId: String(row.account_id) },
        row as any,
        chatFolderTitleAAD(String(row.account_id), String(row.folder_id)),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE chat_folders SET title_key_id = ${sealed.keyId},
        title_nonce = ${sealed.nonce}, title_ciphertext = ${sealed.ciphertext}
        WHERE account_id = ${row.account_id} AND folder_id = ${row.folder_id}
          AND title_key_id = ${fromKeyId} RETURNING folder_id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateScheduledItems(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT item.delivery_id, item.item_index, item.client_msg_id,
           item.payload_key_id AS key_id, item.payload_nonce AS nonce,
           item.payload_ciphertext AS ciphertext, delivery.account_id
    FROM scheduled_delivery_items item
    JOIN scheduled_deliveries delivery ON delivery.id = item.delivery_id
    WHERE item.payload_key_id = ${fromKeyId}
    ORDER BY item.delivery_id, item.item_index
    FOR UPDATE OF item SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      if (!row.nonce || !row.ciphertext) throw new Error("scheduled item has an incomplete ciphertext tuple");
      const sealed = await reseal(
        sql,
        { kind: "account", accountId: String(row.account_id) },
        row as any,
        scheduledItemAAD(
          String(row.account_id), String(row.delivery_id), n(row.item_index), String(row.client_msg_id),
        ),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE scheduled_delivery_items
        SET payload_key_id = ${sealed.keyId}, payload_nonce = ${sealed.nonce},
            payload_ciphertext = ${sealed.ciphertext}
        WHERE delivery_id = ${row.delivery_id} AND item_index = ${row.item_index}
          AND payload_key_id = ${fromKeyId} RETURNING item_index`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateLinkPreviewCache(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT url_lookup_hmac, url_key_id AS key_id, url_nonce AS nonce,
           url_ciphertext AS ciphertext
    FROM link_preview_cache_entries WHERE url_key_id = ${fromKeyId}
    ORDER BY url_lookup_hmac FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, [{ kind: "service", serviceName: "link-preview" }], async () => {
    let migrated = 0;
    for (const row of rows) {
      const lookup = Buffer.from(row.url_lookup_hmac).toString("hex");
      const sealed = await reseal(
        sql, { kind: "service", serviceName: "link-preview" }, row as any,
        linkPreviewURLAAD("cache", lookup),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE link_preview_cache_entries
        SET url_key_id = ${sealed.keyId}, url_nonce = ${sealed.nonce},
            url_ciphertext = ${sealed.ciphertext}
        WHERE url_lookup_hmac = ${row.url_lookup_hmac} AND url_key_id = ${fromKeyId}
        RETURNING url_lookup_hmac`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateLinkPreviewMessages(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT relation.dialog_id, relation.msg_id, relation.generation,
           relation.original_url_key_id AS key_id, relation.original_url_nonce AS nonce,
           relation.original_url_ciphertext AS ciphertext, message.sender_account_id
    FROM message_link_previews relation
    JOIN messages message
      ON message.dialog_id = relation.dialog_id AND message.msg_id = relation.msg_id
    WHERE relation.original_url_key_id = ${fromKeyId}
    ORDER BY relation.dialog_id, relation.msg_id
    FOR UPDATE OF relation SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, rows.map((row: any) => ({
    kind: "account", accountId: String(row.sender_account_id),
  })), async () => {
    let migrated = 0;
    for (const row of rows) {
      if (!row.nonce || !row.ciphertext) throw new Error("message preview has an incomplete ciphertext tuple");
      const sealed = await reseal(
        sql,
        { kind: "account", accountId: String(row.sender_account_id) },
        row as any,
        linkPreviewURLAAD(
          "message", `${row.dialog_id}:${n(row.msg_id)}:${n(row.generation)}`,
        ),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE message_link_previews
        SET original_url_key_id = ${sealed.keyId}, original_url_nonce = ${sealed.nonce},
            original_url_ciphertext = ${sealed.ciphertext}
        WHERE dialog_id = ${row.dialog_id} AND msg_id = ${row.msg_id}
          AND original_url_key_id = ${fromKeyId} RETURNING msg_id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

async function migrateLinkPreviewSnapshots(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT id, url_key_id, url_nonce, url_ciphertext,
           metadata_key_id, metadata_nonce, metadata_ciphertext
    FROM link_preview_snapshots
    WHERE url_key_id = ${fromKeyId} OR metadata_key_id = ${fromKeyId}
    ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, [{ kind: "service", serviceName: "link-preview" }], async () => {
    let migrated = 0;
    for (const row of rows) {
      let touched = false;
      if (row.url_key_id === fromKeyId) {
        const sealed = await reseal(sql, { kind: "service", serviceName: "link-preview" }, {
          key_id: row.url_key_id, nonce: row.url_nonce, ciphertext: row.url_ciphertext,
        }, linkPreviewURLAAD("snapshot", String(row.id)));
        if (sealed) {
          const updated = await sql`UPDATE link_preview_snapshots
            SET url_key_id = ${sealed.keyId}, url_nonce = ${sealed.nonce},
                url_ciphertext = ${sealed.ciphertext}
            WHERE id = ${row.id} AND url_key_id = ${fromKeyId} RETURNING id`;
          touched ||= updated.length > 0;
        }
      }
      if (row.metadata_key_id === fromKeyId) {
        const sealed = await reseal(sql, { kind: "service", serviceName: "link-preview" }, {
          key_id: row.metadata_key_id, nonce: row.metadata_nonce, ciphertext: row.metadata_ciphertext,
        }, linkPreviewMetadataAAD(String(row.id)));
        if (sealed) {
          const updated = await sql`UPDATE link_preview_snapshots
            SET metadata_key_id = ${sealed.keyId}, metadata_nonce = ${sealed.nonce},
                metadata_ciphertext = ${sealed.ciphertext}
            WHERE id = ${row.id} AND metadata_key_id = ${fromKeyId} RETURNING id`;
          touched ||= updated.length > 0;
        }
      }
      if (touched) migrated += 1;
    }
    return migrated;
  });
}

async function migrateLinkPreviewAssets(
  sql: SQL, fromKeyId: string, limit: number,
): Promise<MigrationBatchResult> {
  const rows = await sql`
    SELECT id, key_id, nonce, ciphertext FROM link_preview_assets
    WHERE key_id = ${fromKeyId}
    ORDER BY id FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
  return migrationBatch(sql, [{ kind: "service", serviceName: "link-preview" }], async () => {
    let migrated = 0;
    for (const row of rows) {
      const sealed = await reseal(
        sql, { kind: "service", serviceName: "link-preview" }, row as any,
        linkPreviewAssetAAD(String(row.id)),
      );
      if (!sealed) continue;
      const updated = await sql`UPDATE link_preview_assets
        SET key_id = ${sealed.keyId}, nonce = ${sealed.nonce}, ciphertext = ${sealed.ciphertext}
        WHERE id = ${row.id} AND key_id = ${fromKeyId} RETURNING id`;
      migrated += updated.length;
    }
    return migrated;
  });
}

const handlers: Record<EnvelopeMigrationDomain, (
  sql: SQL, fromKeyId: string, limit: number,
) => Promise<MigrationBatchResult>> = {
  "phone-identity": migratePhoneIdentity,
  messages: migrateMessages,
  "message-polls": migrateMessagePolls,
  drafts: migrateDrafts,
  "draft-responses": migrateDraftResponses,
  "push-tokens": migratePushTokens,
  "installation-push-tokens": migrateInstallationPushTokens,
  "session-rotation-receipts": migrateSessionRotationReceipts,
  "media-metadata": migrateMediaMetadata,
  "media-chunks": migrateMediaChunks,
  "moderation-evidence": migrateModerationEvidence,
  "moderation-notes": migrateModerationNotes,
  "chat-folder-titles": migrateChatFolderTitles,
  "scheduled-items": migrateScheduledItems,
  "link-preview-cache": migrateLinkPreviewCache,
  "link-preview-messages": migrateLinkPreviewMessages,
  "link-preview-snapshots": migrateLinkPreviewSnapshots,
  "link-preview-assets": migrateLinkPreviewAssets,
};

async function remaining(sql: SQL, domain: EnvelopeMigrationDomain, keyId: string): Promise<number> {
  let rows: any[];
  switch (domain) {
    case "phone-identity":
      rows = await sql`SELECT 1 FROM accounts WHERE phone_key_id = ${keyId} LIMIT 1`;
      break;
    case "messages":
      rows = await sql`SELECT 1 FROM messages WHERE body_key_id = ${keyId} LIMIT 1`;
      break;
    case "message-polls":
      rows = await sql`SELECT 1 FROM message_polls WHERE payload_key_id = ${keyId} LIMIT 1`;
      break;
    case "drafts":
      rows = await sql`SELECT 1 FROM account_dialog_drafts WHERE body_key_id = ${keyId} LIMIT 1`;
      break;
    case "draft-responses":
      rows = await sql`SELECT 1 FROM draft_mutation_requests WHERE response_key_id = ${keyId} LIMIT 1`;
      break;
    case "push-tokens":
      rows = await sql`SELECT 1 FROM devices
        WHERE push_token_key_id = ${keyId} OR voip_push_token_key_id = ${keyId} LIMIT 1`;
      break;
    case "installation-push-tokens":
      rows = await sql`SELECT 1 FROM push_installations
        WHERE normal_token_key_id = ${keyId} OR voip_token_key_id = ${keyId} LIMIT 1`;
      break;
    case "session-rotation-receipts":
      rows = await sql`SELECT 1 FROM session_rotation_receipts
        WHERE response_key_id = ${keyId} LIMIT 1`;
      break;
    case "media-metadata":
      rows = await sql`SELECT 1 FROM media_objects
        WHERE file_name_key_id = ${keyId} OR thumbnail_key_id = ${keyId} LIMIT 1`;
      break;
    case "media-chunks":
      rows = await sql`SELECT 1 FROM media_chunks WHERE key_id = ${keyId} LIMIT 1`;
      break;
    case "moderation-evidence":
      rows = await sql`SELECT 1 FROM abuse_reports WHERE evidence_key_id = ${keyId} LIMIT 1`;
      break;
    case "moderation-notes":
      rows = await sql`SELECT 1 FROM abuse_report_actions WHERE note_key_id = ${keyId} LIMIT 1`;
      break;
    case "chat-folder-titles":
      rows = await sql`SELECT 1 FROM chat_folders WHERE title_key_id = ${keyId} LIMIT 1`;
      break;
    case "scheduled-items":
      rows = await sql`SELECT 1 FROM scheduled_delivery_items WHERE payload_key_id = ${keyId} LIMIT 1`;
      break;
    case "link-preview-cache":
      rows = await sql`SELECT 1 FROM link_preview_cache_entries WHERE url_key_id = ${keyId} LIMIT 1`;
      break;
    case "link-preview-messages":
      rows = await sql`SELECT 1 FROM message_link_previews
        WHERE original_url_key_id = ${keyId} LIMIT 1`;
      break;
    case "link-preview-snapshots":
      rows = await sql`SELECT 1 FROM link_preview_snapshots
        WHERE url_key_id = ${keyId} OR metadata_key_id = ${keyId} LIMIT 1`;
      break;
    case "link-preview-assets":
      rows = await sql`SELECT 1 FROM link_preview_assets WHERE key_id = ${keyId} LIMIT 1`;
      break;
  }
  return rows.length;
}

export async function migrateEnvelopeBatch(
  sql: SQL,
  domain: EnvelopeMigrationDomain,
  options: { fromKeyId?: string; batchSize?: number } = {},
): Promise<MigrationResult> {
  const fromKeyId = options.fromKeyId ?? "dev-v1";
  const batchSize = Math.max(1, Math.min(1_000, options.batchSize ?? 100));
  return await sql.begin(async (tx) => {
    await tx`SELECT pg_advisory_xact_lock(hashtextextended(
      ${`envelope-migration:${domain}:${fromKeyId}`}, 0
    ))`;
    await tx`INSERT INTO crypto_migration_cursors(domain, cursor, state)
      VALUES (${`${domain}:${fromKeyId}`}, ${JSON.stringify({ fromKeyId })}::jsonb, 'running')
      ON CONFLICT (domain) DO UPDATE SET state = 'running', updated_at = now()`;
    const requiredIndexes = MIGRATION_INDEXES[domain];
    const indexRows = await tx`
      SELECT class.relname AS name, index.indisvalid, index.indisready
      FROM pg_index index
      JOIN pg_class class ON class.oid = index.indexrelid
      JOIN pg_namespace namespace ON namespace.oid = class.relnamespace
      WHERE namespace.nspname = current_schema()
        AND class.relname = ANY(${tx.array(requiredIndexes, "text")}::text[])`;
    const readyIndexes = new Set(indexRows.filter((row: any) => row.indisvalid && row.indisready)
      .map((row: any) => String(row.name)));
    const missingIndexes = requiredIndexes.filter((name) => !readyIndexes.has(name));
    if (missingIndexes.length) {
      throw new Error(`envelope migration indexes unavailable: ${missingIndexes.join(", ")}`);
    }
    if (fromKeyId !== "dev-v1") {
      const source = (await tx`
        SELECT state FROM account_data_keys WHERE id = ${fromKeyId}
        UNION ALL SELECT state FROM service_data_keys WHERE id = ${fromKeyId}`)[0];
      if (!source) throw new Error(`source data key not found: ${fromKeyId}`);
      if (source.state === "active") throw new Error("cannot migrate from an active data key");
    }
    const batch = await handlers[domain](tx, fromKeyId, batchSize);
    const migrated = batch.migrated;
    const left = await remaining(tx, domain, fromKeyId);
    const retryable = left !== 0 && batch.contended;
    if (left !== 0 && migrated === 0 && !retryable) {
      throw new Error(`envelope migration made no progress for ${domain}:${fromKeyId}`);
    }
    await tx`UPDATE crypto_migration_cursors
      SET state = ${left === 0 ? "complete" : "running"},
          rows_migrated = rows_migrated + ${migrated},
          cursor = ${JSON.stringify({
            fromKeyId, remaining: left, lastBatch: migrated, retryable,
          })}::jsonb,
          updated_at = now()
      WHERE domain = ${`${domain}:${fromKeyId}`}`;
    return { domain, migrated, remaining: left, retryable };
  });
}

export async function envelopeMigrationStatus(sql: SQL): Promise<any[]> {
  return await sql`SELECT domain, cursor, state, rows_migrated, updated_at
    FROM crypto_migration_cursors ORDER BY domain`;
}
