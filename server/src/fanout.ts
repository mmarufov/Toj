import type { SQL } from "bun";
import { dialogPreferenceBehaviorAvailable } from "./dialog-preference-readiness";

export type FanoutPush = { accountId: string; pts: number; ptsCount: number };

type FanoutOptions = {
  dialogId: string;
  type: string;
  actorAccountId: string;
  sourceDeviceId?: string | null;
  msgId?: number | null;
  data?: Record<string, unknown>;
  /** Extra account-private fields attached only to the actor's copy of the event. */
  actorData?: Record<string, unknown>;
  alertRecipients?: boolean;
  recipientAccountIds?: string[];
  unarchiveOnIncomingMessage?: boolean;
  useDialogPreferences?: boolean;
};

const n = (value: unknown) => Number(value as any);

/**
 * Appends an event for any number of recipients with bounded database round trips. Row locks for
 * account_sync_states are acquired in account UUID order before the set-based update.
 */
export async function fanoutDialogEvent(sql: SQL, options: FanoutOptions): Promise<FanoutPush[]> {
  const useDialogPreferences = options.useDialogPreferences
    ?? await dialogPreferenceBehaviorAvailable(sql);
  const unarchived = options.unarchiveOnIncomingMessage && useDialogPreferences
    ? await sql`
        UPDATE dialog_preferences
        SET is_archived = FALSE, updated_at = statement_timestamp()
        WHERE dialog_id = ${options.dialogId}
          AND account_id <> ${options.actorAccountId}
          AND is_archived = TRUE
          AND is_muted = FALSE
          AND EXISTS (
            SELECT 1
            FROM dialog_members active_member
            WHERE active_member.dialog_id = dialog_preferences.dialog_id
              AND active_member.account_id = dialog_preferences.account_id
              AND active_member.left_at IS NULL
          )
        RETURNING account_id`
    : [];
  const unarchivedAccountIds = unarchived.map((row: any) => String(row.account_id));
  const selected = options.recipientAccountIds
    ? await sql`
        SELECT dm.account_id,
               CASE WHEN ${useDialogPreferences}
                 THEN COALESCE(NOT preference.is_muted, dm.notification_mode <> 'muted')
                 ELSE dm.notification_mode <> 'muted'
               END AS alert
        FROM dialog_members dm
        JOIN dialogs d ON d.id = dm.dialog_id
        LEFT JOIN dialog_preferences preference
          ON preference.dialog_id = dm.dialog_id AND preference.account_id = dm.account_id
        WHERE dm.dialog_id = ${options.dialogId}
          AND dm.left_at IS NULL
          AND dm.account_id = ANY(${sql.array(options.recipientAccountIds, "uuid")}::uuid[])
          AND (
            d.type <> 'saved'
            OR (d.created_by = dm.account_id AND dm.role = 'owner')
          )
        ORDER BY dm.account_id`
    : await sql`
        SELECT dm.account_id,
               CASE WHEN ${useDialogPreferences}
                 THEN COALESCE(NOT preference.is_muted, dm.notification_mode <> 'muted')
                 ELSE dm.notification_mode <> 'muted'
               END AS alert
        FROM dialog_members dm
        JOIN dialogs d ON d.id = dm.dialog_id
        LEFT JOIN dialog_preferences preference
          ON preference.dialog_id = dm.dialog_id AND preference.account_id = dm.account_id
        WHERE dm.dialog_id = ${options.dialogId} AND dm.left_at IS NULL
          AND (
            d.type <> 'saved'
            OR (d.created_by = dm.account_id AND dm.role = 'owner')
          )
        ORDER BY dm.account_id`;
  if (selected.length === 0) return [];

  const accountIds = selected.map((row: any) => String(row.account_id));
  const events = await sql`
    WITH locked AS MATERIALIZED (
      SELECT account_id
      FROM account_sync_states
      WHERE account_id = ANY(${sql.array(accountIds, "uuid")}::uuid[])
      ORDER BY account_id
      FOR NO KEY UPDATE
    ), bumped AS (
      UPDATE account_sync_states AS state
      SET pts = state.pts + 1, updated_at = now()
      FROM locked
      WHERE state.account_id = locked.account_id
      RETURNING state.account_id, state.pts
    )
    INSERT INTO account_events (
      account_id, pts, type, dialog_id, msg_id, actor_account_id, data
    )
    SELECT bumped.account_id, bumped.pts, ${options.type}, ${options.dialogId},
           ${options.msgId ?? null}, ${options.actorAccountId},
           ${JSON.stringify(options.data ?? {})}::text::jsonb ||
           CASE
             WHEN bumped.account_id = ${options.actorAccountId}
             THEN ${JSON.stringify(options.actorData ?? {})}::text::jsonb
             ELSE '{}'::jsonb
           END ||
           CASE
             WHEN ${options.type === "dialog.created"} THEN jsonb_build_object(
               'preferences',
               jsonb_build_object(
                 'dialogId', ${options.dialogId}::uuid,
                 'pinned', COALESCE(preference.is_pinned, FALSE),
                 'pinnedAt', preference.pinned_at,
                 'muted', COALESCE(
                   preference.is_muted,
                   member.notification_mode = 'muted'
                 ),
                 'archived', COALESCE(preference.is_archived, FALSE),
                 'updatedAt', COALESCE(preference.updated_at, member.joined_at)
               )
             )
             WHEN bumped.account_id = ANY(
               ${sql.array(unarchivedAccountIds, "uuid")}::uuid[]
             ) THEN jsonb_build_object(
               'preferences',
               jsonb_build_object(
                 'dialogId', ${options.dialogId}::uuid,
                 'pinned', preference.is_pinned,
                 'pinnedAt', preference.pinned_at,
                 'muted', preference.is_muted,
                 'archived', preference.is_archived,
                 'updatedAt', preference.updated_at
               )
             )
             ELSE '{}'::jsonb
           END
    FROM bumped
    LEFT JOIN dialog_preferences preference
      ON preference.dialog_id = ${options.dialogId}
     AND preference.account_id = bumped.account_id
    LEFT JOIN dialog_members member
      ON member.dialog_id = ${options.dialogId}
     AND member.account_id = bumped.account_id
    ORDER BY bumped.account_id
    RETURNING account_id, pts`;

  const eventByAccount = new Map(events.map((row: any) => [String(row.account_id), n(row.pts)]));
  const ptsList = accountIds.map((id) => eventByAccount.get(id)!);
  const alerts = selected.map((row: any) =>
    options.alertRecipients === false ? false : Boolean(row.alert)
  );
  const sourceDeviceId = options.sourceDeviceId ?? null;
  await sql`
    INSERT INTO push_deliveries (account_id, pts, device_id, alert)
    SELECT event.account_id, event.pts, device.id,
           (event.alert AND event.account_id <> ${options.actorAccountId})
    FROM unnest(
      ${sql.array(accountIds, "uuid")}::uuid[],
      ${sql.array(ptsList, "int8")}::bigint[],
      ${sql.array(alerts, "bool")}::boolean[]
    ) AS event(account_id, pts, alert)
    JOIN devices device ON device.account_id = event.account_id
    WHERE device.platform = 'ios'
      AND device.revoked_at IS NULL
      AND (
        (device.push_token_hash IS NOT NULL AND device.push_token_ciphertext IS NOT NULL)
        OR EXISTS (
          SELECT 1 FROM push_account_bindings binding
          JOIN push_installations installation USING (installation_id)
          WHERE binding.device_id = device.id AND binding.account_id = device.account_id
            AND binding.active AND binding.normal_enabled
            AND installation.normal_token_ciphertext IS NOT NULL
        )
      )
      AND (${sourceDeviceId}::uuid IS NULL OR device.id <> ${sourceDeviceId}::uuid)
    ON CONFLICT (account_id, pts, device_id) DO NOTHING`;

  return accountIds.map((accountId) => ({
    accountId,
    pts: eventByAccount.get(accountId)!,
    ptsCount: 1,
  }));
}

/** Emits a purge-only event after membership has already been removed. */
export async function appendAccessRevokedEvent(
  sql: SQL,
  accountId: string,
  dialogId: string,
  actorAccountId: string,
  dialogType: "group" | "saved",
): Promise<FanoutPush> {
  const state = (await sql`
    UPDATE account_sync_states
    SET pts = pts + 1, updated_at = now()
    WHERE account_id = ${accountId}
    RETURNING pts`)[0];
  const pts = n(state.pts);
  await sql`
    INSERT INTO account_events (account_id, pts, type, dialog_id, actor_account_id, data)
    VALUES (
      ${accountId}, ${pts}, 'dialog.access_revoked', ${dialogId}, ${actorAccountId},
      ${JSON.stringify({ dialog_type: dialogType })}::text::jsonb
    )`;
  await sql`
    INSERT INTO push_deliveries (account_id, pts, device_id, alert)
    SELECT ${accountId}, ${pts}, id, false
    FROM devices
    WHERE account_id = ${accountId} AND platform = 'ios' AND revoked_at IS NULL
      AND (
        (push_token_hash IS NOT NULL AND push_token_ciphertext IS NOT NULL)
        OR EXISTS (
          SELECT 1 FROM push_account_bindings binding
          JOIN push_installations installation USING (installation_id)
          WHERE binding.device_id = devices.id AND binding.account_id = devices.account_id
            AND binding.active AND binding.normal_enabled
            AND installation.normal_token_ciphertext IS NOT NULL
        )
      )
    ON CONFLICT (account_id, pts, device_id) DO NOTHING`;
  return { accountId, pts, ptsCount: 1 };
}
