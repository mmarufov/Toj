import type { SQL } from "bun";
import { createHash } from "node:crypto";
import {
  fanoutProfileUpdate,
  profileDTO,
  requireActiveDevice,
  type ProfileDTO,
  type ProfilePush,
} from "./auth";
import { loadMediaDTO } from "./media";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PROFILE_PHOTO_MUTATIONS_PER_DAY = 120;

export class ProfilePhotoError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status = 400,
  ) {
    super(message);
    this.name = "ProfilePhotoError";
  }
}

export type ProfilePhotoMutationResult = {
  profile: ProfileDTO;
  committedPhotoRevision: number;
  duplicate: boolean;
  pushes: ProfilePush[];
};

function requireUUID(value: unknown, field: string): string {
  const normalized = String(value ?? "").toLowerCase();
  if (!UUID_PATTERN.test(normalized)) {
    throw new ProfilePhotoError(`${field} must be a UUID`, "invalid_request");
  }
  return normalized;
}

function requireRevision(value: unknown): number {
  const revision = Number(value);
  if (!Number.isSafeInteger(revision) || revision < 0) {
    throw new ProfilePhotoError("basePhotoRevision must be a non-negative integer", "invalid_request");
  }
  return revision;
}

function sameBuffer(left: unknown, right: Buffer): boolean {
  return Buffer.from(left as Uint8Array).equals(right);
}

async function canonicalProfile(sql: SQL, accountId: string): Promise<ProfileDTO> {
  const row = (await sql`
    SELECT id, username, first_name, last_name, display_name, bio, birthday, profile_color,
           profile_photo_media_id, profile_photo_revision, updated_at
    FROM accounts
    WHERE id = ${accountId} AND status IN ('active','limited')`)[0];
  if (!row) throw new ProfilePhotoError("account unavailable", "account_unavailable", 403);
  return profileDTO(row, await loadMediaDTO(sql, row.profile_photo_media_id));
}

export async function profilePhotosSchemaReadiness(sql: SQL): Promise<{ ready: boolean }> {
  const row = (await sql`
    SELECT
      pg_catalog.to_regclass('public.profile_photo_mutations') IS NOT NULL AS mutations_present,
      pg_catalog.to_regclass('public.profile_photo_action_budgets') IS NOT NULL AS budgets_present,
      EXISTS (
        SELECT 1 FROM schema_migrations
        WHERE name = 'media-purpose-profile-photo-v1'
      ) AS purpose_migration_complete,
      EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'accounts'
          AND column_name = 'profile_photo_media_id'
      ) AS media_column_present,
      EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'accounts'
          AND column_name = 'profile_photo_revision'
          AND data_type = 'bigint' AND is_nullable = 'NO'
      ) AS revision_column_present,
      EXISTS (
        SELECT 1
        FROM pg_constraint constraint_row
        JOIN pg_class table_row ON table_row.oid = constraint_row.conrelid
        JOIN pg_namespace schema_row ON schema_row.oid = table_row.relnamespace
        WHERE schema_row.nspname = 'public' AND table_row.relname = 'accounts'
          AND constraint_row.conname = 'accounts_profile_photo_media_id_fkey'
          AND constraint_row.contype = 'f' AND constraint_row.convalidated
      ) AS media_foreign_key_ready,
      EXISTS (
        SELECT 1
        FROM pg_constraint constraint_row
        JOIN pg_class table_row ON table_row.oid = constraint_row.conrelid
        JOIN pg_namespace schema_row ON schema_row.oid = table_row.relnamespace
        WHERE schema_row.nspname = 'public' AND table_row.relname = 'accounts'
          AND constraint_row.conname = 'accounts_profile_photo_revision_check'
          AND constraint_row.contype = 'c' AND constraint_row.convalidated
      ) AS revision_constraint_ready,
      EXISTS (
        SELECT 1
        FROM pg_constraint constraint_row
        JOIN pg_class table_row ON table_row.oid = constraint_row.conrelid
        JOIN pg_namespace schema_row ON schema_row.oid = table_row.relnamespace
        WHERE schema_row.nspname = 'public' AND table_row.relname = 'media_objects'
          AND constraint_row.conname = 'media_objects_purpose_check'
          AND constraint_row.contype = 'c' AND constraint_row.convalidated
          AND pg_get_constraintdef(constraint_row.oid) LIKE '%profile_photo%'
      ) AS purpose_constraint_ready,
      EXISTS (
        SELECT 1
        FROM pg_constraint constraint_row
        JOIN pg_class table_row ON table_row.oid = constraint_row.conrelid
        JOIN pg_namespace schema_row ON schema_row.oid = table_row.relnamespace
        WHERE schema_row.nspname = 'public' AND table_row.relname = 'profile_photo_mutations'
          AND constraint_row.contype = 'p'
      ) AS mutation_primary_key_ready,
      (SELECT count(*) = 4
       FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'profile_photo_action_budgets'
         AND ((column_name = 'account_id' AND data_type = 'uuid' AND is_nullable = 'NO')
           OR (column_name = 'bucket_started' AND data_type = 'timestamp with time zone'
               AND is_nullable = 'NO')
           OR (column_name = 'mutation_count' AND data_type = 'integer' AND is_nullable = 'NO')
           OR (column_name = 'updated_at' AND data_type = 'timestamp with time zone'
               AND is_nullable = 'NO'))) AS budget_columns_ready,
      EXISTS (
        SELECT 1
        FROM pg_constraint constraint_row
        JOIN pg_class table_row ON table_row.oid = constraint_row.conrelid
        JOIN pg_namespace schema_row ON schema_row.oid = table_row.relnamespace
        WHERE schema_row.nspname = 'public'
          AND table_row.relname = 'profile_photo_action_budgets'
          AND constraint_row.contype = 'p'
      ) AS budget_primary_key_ready,
      to_regclass('public.profile_photo_action_budgets_retention_idx') IS NOT NULL
        AS budget_retention_index_ready,
      EXISTS (
        SELECT 1
        FROM pg_index index_row
        JOIN pg_class class_row ON class_row.oid = index_row.indexrelid
        JOIN pg_namespace schema_row ON schema_row.oid = class_row.relnamespace
        WHERE schema_row.nspname = 'public'
          AND class_row.relname = 'accounts_profile_photo_media_idx'
          AND index_row.indisvalid AND index_row.indisready
      ) AS media_reference_index_ready`)[0];
  return {
    ready: Boolean(
      row?.mutations_present && row?.budgets_present && row?.purpose_migration_complete
      && row?.media_column_present && row?.revision_column_present
      && row?.media_foreign_key_ready && row?.revision_constraint_ready
      && row?.purpose_constraint_ready && row?.mutation_primary_key_ready
      && row?.budget_columns_ready && row?.budget_primary_key_ready
      && row?.budget_retention_index_ready
      && row?.media_reference_index_ready,
    ),
  };
}

export async function updateProfilePhoto(
  sql: SQL,
  input: {
    accountId: string;
    deviceId: string;
    mediaId?: unknown;
    clientMutationId?: unknown;
    basePhotoRevision?: unknown;
  },
): Promise<ProfilePhotoMutationResult> {
  const mutationId = requireUUID(input.clientMutationId, "clientMutationId");
  const mediaId = input.mediaId == null ? null : requireUUID(input.mediaId, "mediaId");
  const baseRevision = requireRevision(input.basePhotoRevision);
  const fingerprint = createHash("sha256")
    .update(JSON.stringify([mediaId, baseRevision]))
    .digest();

  return await sql.begin(async (tx) => {
    const account = (await tx`
      SELECT id, username, first_name, last_name, display_name, bio, birthday, profile_color,
             profile_photo_media_id, profile_photo_revision, updated_at
      FROM accounts
      WHERE id = ${input.accountId} AND status IN ('active','limited')
      FOR UPDATE`)[0];
    if (!account) {
      throw new ProfilePhotoError("account unavailable", "account_unavailable", 403);
    }
    await requireActiveDevice(tx, input.accountId, input.deviceId);

    // Receipts deliberately outlive the media they once referenced. Reauthorize the current
    // account and device first, then honor an exact completed replay before validating resources
    // that are only required for a new mutation.
    const existing = (await tx`
      SELECT payload_fingerprint, status, result_revision
      FROM profile_photo_mutations
      WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}
      FOR UPDATE`)[0];
    if (existing) {
      if (!sameBuffer(existing.payload_fingerprint, fingerprint)) {
        throw new ProfilePhotoError(
          "mutation id was reused with different details", "idempotency_conflict", 409,
        );
      }
      if (existing.status !== "completed" || existing.result_revision == null) {
        throw new ProfilePhotoError(
          "profile photo mutation is already in progress", "mutation_in_progress", 409,
        );
      }
      return {
        profile: await canonicalProfile(tx, input.accountId),
        committedPhotoRevision: Number(existing.result_revision),
        duplicate: true,
        pushes: [],
      };
    }

    if (mediaId) {
      const media = (await tx`
        SELECT owner_account_id, kind, content_type, byte_size, width, height, purpose, status
        FROM media_objects WHERE id = ${mediaId}
        FOR UPDATE`)[0];
      if (
        !media || media.owner_account_id !== input.accountId || media.kind !== "photo"
        || media.content_type !== "image/jpeg" || media.purpose !== "profile_photo"
        || media.status !== "ready" || Number(media.byte_size) > 3 * 1024 * 1024
        || Number(media.width) > 1_024 || Number(media.height) > 1_024
      ) {
        throw new ProfilePhotoError(
          "profile photo upload is unavailable", "profile_photo_unavailable", 404,
        );
      }
    }

    const budget = await tx`
      INSERT INTO profile_photo_action_budgets(
        account_id, bucket_started, mutation_count, updated_at
      ) VALUES (${input.accountId}, date_trunc('day', now()), 1, now())
      ON CONFLICT (account_id, bucket_started) DO UPDATE SET
        mutation_count = profile_photo_action_budgets.mutation_count + 1,
        updated_at = now()
      WHERE profile_photo_action_budgets.mutation_count < ${PROFILE_PHOTO_MUTATIONS_PER_DAY}
      RETURNING mutation_count`;
    if (budget.length === 0) {
      throw new ProfilePhotoError(
        "profile photo change limit reached; try again tomorrow",
        "profile_photo_rate_limited",
        429,
      );
    }

    const inserted = await tx`
      INSERT INTO profile_photo_mutations (
        account_id, client_mutation_id, payload_fingerprint, media_id, base_revision
      ) VALUES (
        ${input.accountId}, ${mutationId}, ${fingerprint}, ${mediaId}, ${baseRevision}
      )
      ON CONFLICT (account_id, client_mutation_id) DO NOTHING
      RETURNING client_mutation_id`;
    if (inserted.length === 0) {
      const raced = (await tx`
        SELECT payload_fingerprint, status, result_revision
        FROM profile_photo_mutations
        WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}
        FOR UPDATE`)[0];
      if (!raced || !sameBuffer(raced.payload_fingerprint, fingerprint)) {
        throw new ProfilePhotoError(
          "mutation id was reused with different details", "idempotency_conflict", 409,
        );
      }
      if (raced.status !== "completed" || raced.result_revision == null) {
        throw new ProfilePhotoError(
          "profile photo mutation is already in progress", "mutation_in_progress", 409,
        );
      }
      return {
        profile: await canonicalProfile(tx, input.accountId),
        committedPhotoRevision: Number(raced.result_revision),
        duplicate: true,
        pushes: [],
      };
    }

    const currentRevision = Number(account.profile_photo_revision);
    if (currentRevision !== baseRevision) {
      throw new ProfilePhotoError(
        "profile photo changed on another device", "stale_profile_photo", 409,
      );
    }

    const currentMediaId = account.profile_photo_media_id == null
      ? null
      : String(account.profile_photo_media_id);
    let committedRevision = currentRevision;
    let profile: ProfileDTO;
    let pushes: ProfilePush[] = [];
    if (currentMediaId === mediaId) {
      profile = profileDTO(account, await loadMediaDTO(tx, currentMediaId));
    } else {
      const updated = (await tx`
        UPDATE accounts
        SET profile_photo_media_id = ${mediaId},
            profile_photo_revision = profile_photo_revision + 1,
            updated_at = now()
        WHERE id = ${input.accountId}
        RETURNING id, username, first_name, last_name, display_name, bio, birthday, profile_color,
                  profile_photo_media_id, profile_photo_revision, updated_at`)[0];
      committedRevision = Number(updated.profile_photo_revision);
      profile = profileDTO(updated, await loadMediaDTO(tx, updated.profile_photo_media_id));
      pushes = await fanoutProfileUpdate(tx, input.accountId, input.deviceId, profile);
    }

    await tx`
      UPDATE profile_photo_mutations
      SET status = 'completed', result_revision = ${committedRevision}, completed_at = now()
      WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}`;
    return { profile, committedPhotoRevision: committedRevision, duplicate: false, pushes };
  });
}
