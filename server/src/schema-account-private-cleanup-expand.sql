\set ON_ERROR_STOP on

-- Account rows are privacy-anonymized rather than deleted, so FK cascades are not a lifecycle
-- boundary. Install one database-owned boundary that both current binaries and the existing
-- mixed-version status trigger can call.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE OR REPLACE FUNCTION public.toj_cleanup_account_private_state_v1(
  target_account_id UUID
)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  -- Saved cleanup must run first: it emits ordered revocations for any corrupt legacy members,
  -- detaches immutable forwarding provenance, and preserves media still referenced by a forward.
  PERFORM public.toj_cleanup_saved_messages_for_account(target_account_id);

  -- Durable draft/album replay records and rate-limit receipts are account-private. They cannot
  -- rely on ON DELETE CASCADE because the account row remains as a Deleted Account tombstone.
  DELETE FROM public.draft_mutation_budgets
  WHERE account_id = target_account_id;
  DELETE FROM public.draft_mutation_requests
  WHERE account_id = target_account_id;
  DELETE FROM public.draft_mutation_tombstones
  WHERE account_id = target_account_id;
  DELETE FROM public.media_group_send_budgets
  WHERE account_id = target_account_id;
  DELETE FROM public.media_group_send_requests
  WHERE sender_account_id = target_account_id;
  DELETE FROM public.media_group_send_tombstones
  WHERE sender_account_id = target_account_id;
  DELETE FROM public.account_dialog_drafts
  WHERE account_id = target_account_id;

  -- Reconciliation rows can legitimately outlive their canonical preference after a mixed-node
  -- retry. Delete by account rather than joining through dialog_preferences, otherwise that
  -- already-orphaned queue row would survive account deletion.
  DELETE FROM public.dialog_preference_legacy_reconciliation
  WHERE account_id = target_account_id;
  DELETE FROM public.dialog_preferences
  WHERE account_id = target_account_id;
  DELETE FROM public.dialog_preference_requests
  WHERE account_id = target_account_id;
  DELETE FROM public.dialog_preference_action_budgets
  WHERE account_id = target_account_id;
  DELETE FROM public.profile_photo_mutations
  WHERE account_id = target_account_id;
  DELETE FROM public.profile_photo_action_budgets
  WHERE account_id = target_account_id;

  -- Presence is exact account activity and therefore private deletion state. Dynamic SQL keeps the
  -- cleanup function deployable during an expand phase in which the presence tables may not exist
  -- on every database yet.
  IF to_regclass('public.device_presence_leases') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.device_presence_leases WHERE account_id = $1'
      USING target_account_id;
  END IF;
  IF to_regclass('public.account_presence') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.account_presence WHERE account_id = $1'
      USING target_account_id;
  END IF;

  DELETE FROM public.chat_folder_mutation_requests
  WHERE account_id = target_account_id;
  DELETE FROM public.chat_folder_action_budgets
  WHERE account_id = target_account_id;
  DELETE FROM public.chat_folders
  WHERE account_id = target_account_id;
  DELETE FROM public.account_chat_folder_states
  WHERE account_id = target_account_id;

  -- Accepted schedules belong to the account rather than the originating device. Account deletion
  -- is the explicit terminal boundary: erase ciphertext and all replay receipts before anonymizing.
  DELETE FROM public.scheduled_delivery_mutation_requests
  WHERE account_id = target_account_id;
  DELETE FROM public.scheduled_delivery_action_budgets
  WHERE account_id = target_account_id;
  DELETE FROM public.scheduled_deliveries
  WHERE account_id = target_account_id;
  DELETE FROM public.account_scheduled_delivery_states
  WHERE account_id = target_account_id;
  DELETE FROM public.link_preview_action_budgets
  WHERE account_id = target_account_id;

  -- Security credentials, replay material, and account-scoped feature preferences must not
  -- survive anonymization. The account row is retained, so FK cascades never run here.
  DELETE FROM public.security_step_up_tickets
  WHERE account_id = target_account_id;
  DELETE FROM public.two_factor_attempt_budgets
  WHERE account_id = target_account_id;
  DELETE FROM public.two_factor_login_challenges
  WHERE account_id = target_account_id;
  DELETE FROM public.two_factor_recovery_codes
  WHERE account_id = target_account_id;
  DELETE FROM public.account_two_factor
  WHERE account_id = target_account_id;
  DELETE FROM public.device_sessions AS session
  USING public.devices AS device
  WHERE session.device_id = device.id AND device.account_id = target_account_id;

  DELETE FROM public.messaging_feature_mutations
  WHERE actor_account_id = target_account_id;
  DELETE FROM public.poll_votes
  WHERE voter_account_id = target_account_id;
  DELETE FROM public.account_sticker_favorites
  WHERE account_id = target_account_id;
  DELETE FROM public.account_sticker_recents
  WHERE account_id = target_account_id;
  DELETE FROM public.account_sticker_packs
  WHERE account_id = target_account_id;
  WITH removed AS (
    DELETE FROM public.push_account_bindings
    WHERE account_id = target_account_id
    RETURNING installation_id
  )
  DELETE FROM public.push_installations AS installation
  WHERE installation.installation_id IN (SELECT installation_id FROM removed)
    AND NOT EXISTS (
      SELECT 1 FROM public.push_account_bindings AS binding
      WHERE binding.installation_id = installation.installation_id
    );

  -- Push rows cascade from these private sync events. Message/group lifecycle history belonging to
  -- peers remains intact; only draft and preference presentation state is removed.
  DELETE FROM public.account_events
  WHERE account_id = target_account_id
    AND type IN (
      'draft.updated', 'dialog.preferences_updated', 'chat_folders.updated',
      'scheduled.created', 'scheduled.updated', 'scheduled.canceled', 'scheduled.failed',
      'security.changed', 'sticker_preferences.updated'
    );
  DELETE FROM public.bootstrap_snapshots
  WHERE account_id = target_account_id;

  -- Remove uploads owned by the deleted account only when no surviving message, dialog photo, or
  -- draft references them. media_chunks cascade from media_objects. This deliberately preserves
  -- shared forwarded media and newer legitimate references owned by another account.
  DELETE FROM public.media_objects AS media
  WHERE media.owner_account_id = target_account_id
    AND NOT EXISTS (
      SELECT 1 FROM public.messages AS message
      WHERE message.media_id = media.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.dialogs AS dialog
      WHERE dialog.photo_media_id = media.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.accounts AS account
      WHERE account.profile_photo_media_id = media.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.draft_attachments AS attachment
      WHERE attachment.media_id = media.id
    );
END
$$;

CREATE OR REPLACE FUNCTION public.toj_cleanup_saved_messages_before_account_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF OLD.status <> 'deleted' AND NEW.status = 'deleted' THEN
    PERFORM public.toj_cleanup_account_private_state_v1(OLD.id);
    -- A mixed-version binary may update only status. Clear the reference at the database boundary
    -- so a private profile photo cannot survive anonymization merely because the caller predates
    -- profile photos.
    NEW.profile_photo_media_id := NULL;
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS accounts_cleanup_saved_messages ON public.accounts;
CREATE TRIGGER accounts_cleanup_saved_messages
BEFORE UPDATE OF status ON public.accounts
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION public.toj_cleanup_saved_messages_before_account_delete();

CREATE OR REPLACE FUNCTION public.toj_cleanup_profile_photo_after_account_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF OLD.status <> 'deleted' AND NEW.status = 'deleted'
     AND OLD.profile_photo_media_id IS NOT NULL THEN
    DELETE FROM public.media_objects AS media
    WHERE media.id = OLD.profile_photo_media_id
      AND media.owner_account_id = OLD.id
      AND NOT EXISTS (
        SELECT 1 FROM public.messages AS message WHERE message.media_id = media.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.dialogs AS dialog WHERE dialog.photo_media_id = media.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.accounts AS account WHERE account.profile_photo_media_id = media.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.draft_attachments AS attachment WHERE attachment.media_id = media.id
      );
  END IF;
  RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS accounts_cleanup_profile_photo ON public.accounts;
CREATE TRIGGER accounts_cleanup_profile_photo
AFTER UPDATE OF status ON public.accounts
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION public.toj_cleanup_profile_photo_after_account_delete();

COMMIT;
