import type { SQL } from "bun";
import { pollAAD } from "./crypto";
import { openForScope, sealForScope } from "./envelope-crypto";

export class MessagingContentError extends Error {
  constructor(
    message: string,
    readonly status = 400,
    readonly code = "invalid_message_content",
  ) {
    super(message);
    this.name = "MessagingContentError";
  }
}

export type PollCreationInput = {
  question: string;
  options: string[];
  multipleChoice?: boolean;
  anonymous?: boolean;
  quiz?: boolean;
  correctOptionIndex?: number;
  explanation?: string;
};

export type NormalizedPollCreation = {
  question: string;
  options: string[];
  multipleChoice: boolean;
  anonymous: boolean;
  quiz: boolean;
  correctOptionIndex: number | null;
  explanation: string | null;
};

export type PollDTO = {
  question: string;
  options: Array<{ index: number; text: string; votes?: number }>;
  multiple_choice: boolean;
  anonymous: boolean;
  quiz: boolean;
  closed: boolean;
  total_voters?: number;
  my_option_indices: number[];
  correct_option_index?: number;
  explanation?: string;
};

export type StickerDTO = {
  id: string;
  pack_id: string;
  pack_version: number;
  format: "png" | "apng";
  mime_type: "image/png" | "image/apng";
  byte_size: number;
  width: number;
  height: number;
  sha256: string;
  asset_url: string;
  unavailable: boolean;
};

export type ExternalMediaDTO = {
  provider: "giphy";
  provider_id: string;
  rendition: { width?: number; height?: number; aspect_ratio?: number };
};

type MessageKey = { dialogId: string; msgId: number };

const characterCount = (value: string) => [...value].length;
const key = (dialogId: string, msgId: number) => `${dialogId}:${msgId}`;
const bytes = (value: unknown) => Buffer.from(value as Uint8Array);

export function normalizePollCreation(input: unknown): NormalizedPollCreation {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new MessagingContentError("poll content required");
  }
  const source = input as PollCreationInput;
  const question = typeof source.question === "string" ? source.question.trim() : "";
  if (!question || characterCount(question) > 300) {
    throw new MessagingContentError("poll question must be 1 to 300 characters");
  }
  if (!Array.isArray(source.options) || source.options.length < 2 || source.options.length > 10) {
    throw new MessagingContentError("polls require 2 to 10 options");
  }
  const options = source.options.map((option) => typeof option === "string" ? option.trim() : "");
  if (options.some((option) => !option || characterCount(option) > 100)) {
    throw new MessagingContentError("poll options must be 1 to 100 characters");
  }
  if (new Set(options.map((option) => option.toLocaleLowerCase())).size !== options.length) {
    throw new MessagingContentError("poll options must be unique");
  }
  const multipleChoice = source.multipleChoice === true;
  const anonymous = source.anonymous !== false;
  const quiz = source.quiz === true;
  if (quiz && multipleChoice) {
    throw new MessagingContentError("quiz polls support one answer only");
  }
  const correctOptionIndex = source.correctOptionIndex == null
    ? null
    : Number(source.correctOptionIndex);
  if (quiz && (
    !Number.isSafeInteger(correctOptionIndex)
    || correctOptionIndex! < 0
    || correctOptionIndex! >= options.length
  )) {
    throw new MessagingContentError("quiz polls require a valid correct option");
  }
  if (!quiz && correctOptionIndex != null) {
    throw new MessagingContentError("only quiz polls may define a correct option");
  }
  const explanation = source.explanation == null ? null : String(source.explanation).trim();
  if (explanation && characterCount(explanation) > 200) {
    throw new MessagingContentError("quiz explanation must be at most 200 characters");
  }
  if (!quiz && explanation) {
    throw new MessagingContentError("only quiz polls may define an explanation");
  }
  return {
    question,
    options,
    multipleChoice,
    anonymous,
    quiz,
    correctOptionIndex: quiz ? correctOptionIndex : null,
    explanation: explanation || null,
  };
}

export async function insertPollContent(
  sql: SQL,
  dialogId: string,
  msgId: number,
  input: NormalizedPollCreation,
  senderAccountId: string,
): Promise<void> {
  // Poll payloads follow their message body's key scope so account deletion shreds both.
  const sealed = await sealForScope(sql, { kind: "account", accountId: senderAccountId }, JSON.stringify({
    question: input.question,
    options: input.options,
    correctOptionIndex: input.correctOptionIndex,
    explanation: input.explanation,
  }), pollAAD(dialogId, msgId));
  await sql`
    INSERT INTO message_polls (
      dialog_id, msg_id, payload_key_id, payload_nonce, payload_ciphertext,
      option_count, multiple_choice, anonymous, quiz
    ) VALUES (
      ${dialogId}, ${msgId}, ${sealed.keyId}, ${sealed.nonce}, ${sealed.ciphertext},
      ${input.options.length}, ${input.multipleChoice}, ${input.anonymous}, ${input.quiz}
    )`;
}

export async function copyStructuredMessageContent(
  sql: SQL,
  source: MessageKey,
  destination: MessageKey,
  kind: string,
  destinationSenderAccountId: string,
): Promise<void> {
  if (kind === "poll") {
    const row = (await sql`
      SELECT poll.*, message.sender_account_id AS poll_sender_account_id
      FROM message_polls poll
      JOIN messages message
        ON message.dialog_id = poll.dialog_id AND message.msg_id = poll.msg_id
      WHERE poll.dialog_id = ${source.dialogId} AND poll.msg_id = ${source.msgId}`)[0];
    if (!row) throw new MessagingContentError("forward source poll is unavailable", 409);
    const payload = await decodePollPayload(sql, row);
    // The forwarded copy is re-sealed under the forwarding sender's scope.
    const sealed = await sealForScope(
      sql,
      { kind: "account", accountId: destinationSenderAccountId },
      JSON.stringify(payload),
      pollAAD(destination.dialogId, destination.msgId),
    );
    await sql`
      INSERT INTO message_polls (
        dialog_id, msg_id, payload_key_id, payload_nonce, payload_ciphertext,
        option_count, multiple_choice, anonymous, quiz
      ) VALUES (
        ${destination.dialogId}, ${destination.msgId}, ${sealed.keyId}, ${sealed.nonce},
        ${sealed.ciphertext}, ${row.option_count}, ${row.multiple_choice},
        ${row.anonymous}, ${row.quiz}
      )`;
    return;
  }
  if (kind === "sticker" || kind === "external_media") {
    const copied = await sql`
      INSERT INTO message_external_content (
        dialog_id, msg_id, provider, provider_item_id, pack_id, rendition
      )
      SELECT ${destination.dialogId}, ${destination.msgId}, provider, provider_item_id,
             pack_id, rendition
      FROM message_external_content
      WHERE dialog_id = ${source.dialogId} AND msg_id = ${source.msgId}
      RETURNING msg_id`;
    if (!copied.length) {
      throw new MessagingContentError("forward source content is unavailable", 409);
    }
  }
}

async function decodePollPayload(sql: SQL, row: any): Promise<{
  question: string;
  options: string[];
  correctOptionIndex: number | null;
  explanation: string | null;
}> {
  return JSON.parse((await openForScope(
    sql,
    { kind: "account", accountId: String(row.poll_sender_account_id) },
    {
      keyId: String(row.payload_key_id),
      nonce: bytes(row.payload_nonce),
      ciphertext: bytes(row.payload_ciphertext),
    },
    pollAAD(String(row.dialog_id), Number(row.msg_id)),
  )).toString("utf8"));
}

export async function loadPollDTO(
  sql: SQL,
  dialogId: string,
  msgId: number,
  viewerAccountId: string,
): Promise<PollDTO | null> {
  return (await loadPollDTOs(sql, [{ dialogId, msgId }], viewerAccountId))
    .get(key(dialogId, msgId)) ?? null;
}

export async function loadPollDTOs(
  sql: SQL,
  inputKeys: MessageKey[],
  viewerAccountId: string,
): Promise<Map<string, PollDTO>> {
  const result = new Map<string, PollDTO>();
  if (!inputKeys.length) return result;
  const rows = await sql`
    WITH wanted AS (
      SELECT * FROM unnest(
        ${sql.array(inputKeys.map((item) => item.dialogId), "uuid")}::uuid[],
        ${sql.array(inputKeys.map((item) => item.msgId), "int8")}::bigint[]
      ) AS wanted(dialog_id, msg_id)
    ), option_counts AS (
      SELECT vote.dialog_id, vote.msg_id, expanded.option_index,
             count(*)::int AS votes
      FROM wanted
      JOIN poll_votes vote
        ON vote.dialog_id = wanted.dialog_id AND vote.msg_id = wanted.msg_id
      CROSS JOIN LATERAL unnest(vote.option_indices) AS expanded(option_index)
      GROUP BY vote.dialog_id, vote.msg_id, expanded.option_index
    ), summaries AS (
      SELECT vote.dialog_id, vote.msg_id, count(*)::int AS total_voters
      FROM wanted
      JOIN poll_votes vote
        ON vote.dialog_id = wanted.dialog_id AND vote.msg_id = wanted.msg_id
      GROUP BY vote.dialog_id, vote.msg_id
    )
    SELECT poll.*, message.sender_account_id AS poll_sender_account_id,
           own.option_indices AS my_option_indices,
           COALESCE(summary.total_voters, 0) AS total_voters,
           COALESCE((
             SELECT jsonb_object_agg(option_index::text, votes)
             FROM option_counts stats
             WHERE stats.dialog_id = poll.dialog_id AND stats.msg_id = poll.msg_id
           ), '{}'::jsonb) AS option_counts
    FROM wanted
    JOIN message_polls poll
      ON poll.dialog_id = wanted.dialog_id AND poll.msg_id = wanted.msg_id
    JOIN messages message
      ON message.dialog_id = wanted.dialog_id AND message.msg_id = wanted.msg_id
    LEFT JOIN poll_votes own
      ON own.dialog_id = poll.dialog_id AND own.msg_id = poll.msg_id
     AND own.voter_account_id = ${viewerAccountId}
    LEFT JOIN summaries summary
      ON summary.dialog_id = poll.dialog_id AND summary.msg_id = poll.msg_id
    WHERE message.state = 'visible'
      AND (message.expires_at IS NULL OR message.expires_at > now())`;
  for (const row of rows) {
    result.set(key(String(row.dialog_id), Number(row.msg_id)), await pollDTOFromRow(sql, row));
  }
  return result;
}

/** Pure row projection shared by the standalone poll loader and the sync metadata batch. */
export async function pollDTOFromRow(sql: SQL, row: any): Promise<PollDTO> {
  const payload = await decodePollPayload(sql, row);
  const myOptions = (row.my_option_indices ?? []).map(Number);
  const revealResults = row.closed_at != null || myOptions.length > 0;
  const rawCounts = typeof row.option_counts === "string"
    ? JSON.parse(row.option_counts) : row.option_counts ?? {};
  const counts = Array.from({ length: Number(row.option_count) }, (_, index) =>
    Number(rawCounts[String(index)] ?? 0)
  );
  const revealQuizAnswer = Boolean(row.quiz) && revealResults;
  return {
    question: payload.question,
    options: payload.options.map((text, index) => ({
      index,
      text,
      ...(revealResults ? { votes: counts[index] ?? 0 } : {}),
    })),
    multiple_choice: Boolean(row.multiple_choice),
    anonymous: Boolean(row.anonymous),
    quiz: Boolean(row.quiz),
    closed: row.closed_at != null,
    ...(revealResults ? { total_voters: Number(row.total_voters) } : {}),
    my_option_indices: myOptions,
    ...(revealQuizAnswer && payload.correctOptionIndex != null
      ? { correct_option_index: payload.correctOptionIndex }
      : {}),
    ...(revealQuizAnswer && payload.explanation ? { explanation: payload.explanation } : {}),
  };
}

export function normalizeGiphyReference(input: unknown): {
  providerId: string;
  rendition: { width?: number; height?: number; aspect_ratio?: number };
} {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new MessagingContentError("GIPHY reference required");
  }
  const source = input as Record<string, unknown>;
  const providerId = typeof source.providerId === "string" ? source.providerId.trim() : "";
  if (!/^[A-Za-z0-9_-]{1,200}$/.test(providerId)) {
    throw new MessagingContentError("invalid GIPHY item id");
  }
  const sourceRendition = source.rendition && typeof source.rendition === "object"
    ? source.rendition as Record<string, unknown>
    : {};
  const width = Number(sourceRendition.width);
  const height = Number(sourceRendition.height);
  const rendition: { width?: number; height?: number; aspect_ratio?: number } = {};
  if (Number.isSafeInteger(width) && width > 0 && width <= 4096) rendition.width = width;
  if (Number.isSafeInteger(height) && height > 0 && height <= 4096) rendition.height = height;
  if (rendition.width && rendition.height) rendition.aspect_ratio = rendition.width / rendition.height;
  return { providerId, rendition };
}

export async function insertGiphyContent(
  sql: SQL,
  dialogId: string,
  msgId: number,
  reference: ReturnType<typeof normalizeGiphyReference>,
): Promise<void> {
  await sql`
    INSERT INTO message_external_content (
      dialog_id, msg_id, provider, provider_item_id, rendition
    ) VALUES (
      ${dialogId}, ${msgId}, 'giphy', ${reference.providerId},
      ${JSON.stringify(reference.rendition)}::jsonb
    )`;
}

export async function requireStickerForSend(sql: SQL, stickerId: string): Promise<StickerDTO> {
  if (!/^[A-Za-z0-9._:-]{1,160}$/.test(stickerId)) {
    throw new MessagingContentError("invalid sticker id");
  }
  const row = (await sql`
    SELECT sticker.*, pack.version AS current_pack_version, pack.status AS pack_status
    FROM stickers sticker JOIN sticker_packs pack ON pack.id = sticker.pack_id
    WHERE sticker.id = ${stickerId}`)[0];
  if (!row || row.status !== "active" || row.pack_status !== "active") {
    throw new MessagingContentError("sticker is unavailable", 409, "sticker_unavailable");
  }
  if (Number(row.pack_version) !== Number(row.current_pack_version)) {
    throw new MessagingContentError("sticker pack update required", 409, "sticker_pack_outdated");
  }
  return stickerDTOFromRow(row);
}

export async function insertStickerContent(
  sql: SQL,
  dialogId: string,
  msgId: number,
  sticker: StickerDTO,
): Promise<void> {
  await sql`
    INSERT INTO message_external_content (
      dialog_id, msg_id, provider, provider_item_id, pack_id, rendition
    ) VALUES (
      ${dialogId}, ${msgId}, 'toj_sticker', ${sticker.id}, ${sticker.pack_id},
      ${JSON.stringify({
        pack_version: sticker.pack_version,
        width: sticker.width,
        height: sticker.height,
        format: sticker.format,
        sha256: sticker.sha256,
      })}::jsonb
    )`;
}

function stickerDTOFromRow(row: any): StickerDTO {
  return {
    id: String(row.id ?? row.provider_item_id),
    pack_id: String(row.pack_id),
    pack_version: Number(row.pack_version ?? row.rendition?.pack_version ?? 0),
    format: String(row.format ?? row.rendition?.format ?? "png") as "png" | "apng",
    mime_type: String(row.mime_type ?? (row.format === "apng" ? "image/apng" : "image/png")) as StickerDTO["mime_type"],
    byte_size: Number(row.byte_size ?? 0),
    width: Number(row.width ?? row.rendition?.width ?? 0),
    height: Number(row.height ?? row.rendition?.height ?? 0),
    sha256: row.sha256 ? bytes(row.sha256).toString("hex") : String(row.rendition?.sha256 ?? ""),
    asset_url: String(row.asset_url ?? ""),
    unavailable: row.status === "withdrawn" || row.pack_status === "withdrawn" || !row.asset_url,
  };
}

/** Pure row projection shared by the standalone content loader and the sync metadata batch. */
export function externalContentDTOFromRow(row: any): {
  sticker: StickerDTO | null;
  externalMedia: ExternalMediaDTO | null;
} {
  const rendition = typeof row.rendition === "string" ? JSON.parse(row.rendition) : row.rendition;
  if (row.provider === "giphy") {
    return {
      sticker: null,
      externalMedia: {
        provider: "giphy",
        provider_id: String(row.provider_item_id),
        rendition: rendition ?? {},
      },
    };
  }
  return {
    sticker: stickerDTOFromRow({ ...row, rendition }),
    externalMedia: null,
  };
}

export async function loadExternalContentDTOs(
  sql: SQL,
  inputKeys: MessageKey[],
): Promise<{
  stickers: Map<string, StickerDTO>;
  externalMedia: Map<string, ExternalMediaDTO>;
}> {
  const stickers = new Map<string, StickerDTO>();
  const externalMedia = new Map<string, ExternalMediaDTO>();
  if (!inputKeys.length) return { stickers, externalMedia };
  const rows = await sql`
    WITH wanted AS (
      SELECT * FROM unnest(
        ${sql.array(inputKeys.map((item) => item.dialogId), "uuid")}::uuid[],
        ${sql.array(inputKeys.map((item) => item.msgId), "int8")}::bigint[]
      ) AS wanted(dialog_id, msg_id)
    )
    SELECT content.*, sticker.format, sticker.mime_type, sticker.byte_size,
           sticker.width, sticker.height, sticker.sha256, sticker.asset_url,
           sticker.status, pack.status AS pack_status,
           COALESCE(sticker.pack_version, (content.rendition->>'pack_version')::int) AS pack_version
    FROM wanted
    JOIN message_external_content content USING (dialog_id, msg_id)
    LEFT JOIN stickers sticker ON content.provider = 'toj_sticker'
      AND sticker.id = content.provider_item_id
    LEFT JOIN sticker_packs pack ON pack.id = content.pack_id`;
  for (const row of rows) {
    const messageKey = key(String(row.dialog_id), Number(row.msg_id));
    const projected = externalContentDTOFromRow(row);
    if (projected.externalMedia) externalMedia.set(messageKey, projected.externalMedia);
    if (projected.sticker) stickers.set(messageKey, projected.sticker);
  }
  return { stickers, externalMedia };
}
