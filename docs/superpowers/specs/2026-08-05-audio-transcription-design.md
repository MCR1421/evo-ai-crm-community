# Audio transcription for vascaino_core (WhatsApp voice notes)

## Problem

The `vascaino_core` AgentBot (EvoCRM's AI order-bot, see `evo_core_agents` id `d2510404-b6d5-42ae-b037-4a0f51e7895e`) never receives audio content. Chatwoot/Rails downloads and stores voice-note attachments correctly (`ActiveStorage`, `Attachment#file_url` works), but `BotRuntime::DelegationService#build_message_event` only forwards `message_content: @message.content.to_s` — no attachment reference at all. A customer's voice note reaches the bot as empty (or caption-only) text; the bot has no idea audio was sent.

This is layer 2 of a previously-documented 3-layer gap (Rails OK → Go BotRuntime drops attachments → Python processor is audio-partial/no-STT anyway). This spec fixes the gap for **audio only**, entirely inside Rails, without touching the Go (`evo-bot-runtime`) or Python (`evo-ai-processor-community`) layers. Image support is out of scope and would need separate work.

## Approach

Transcribe the audio to text in Rails, before the message ever leaves Rails, so it reaches `BotRuntime`/the processor as ordinary customer text — indistinguishable from a typed message. This reuses the exact approach already proven working in the old n8n bot (a plain HTTP node calling Groq's OpenAI-compatible Whisper endpoint), and requires zero changes to the Go delegation protocol or the Python A2A layer.

Rejected alternatives:
- **Transcribe inside BotRuntime (Go)**: no benefit — Rails already has the downloaded file; just moves the same HTTP call one hop later for no reason.
- **Build a general file-carrying pipe** (extend Go's `JSONRPCPart`, forward raw audio to the Python processor, transcribe or use native audio understanding there): the architecturally "complete" answer that would also help future image support, but touches 3 languages/repos to solve a problem the Rails-only approach solves with one new service + one new job. Not justified for audio-only scope.

## Components

### 1. `BotRuntime::AudioTranscriptionService` (new)
`app/services/bot_runtime/audio_transcription_service.rb`

- Input: an attachment's `file_url`.
- Downloads the audio bytes, POSTs multipart/form-data to `https://api.groq.com/openai/v1/audio/transcriptions`:
  - `model: "whisper-large-v3"`, `language: "pt"`, `response_format: "json"`, `file` field with the audio binary.
  - `Authorization: Bearer #{ENV['GROQ_API_KEY']}`
  - 30s timeout (matches the retired n8n node's configuration).
- Returns the transcript string on success.
- Raises a service-specific error (`BotRuntime::AudioTranscriptionService::TranscriptionError`) on any failure (network error, non-2xx, missing/empty transcript in response) so callers can rescue narrowly instead of catching `StandardError`.

`GROQ_API_KEY` is a new env var. Do not reuse the API key that was hardcoded in plaintext in the old n8n node — generate/rotate a fresh key in Groq's console for this integration.

### 2. `BotRuntime::TranscribeAudioJob` (new, `ActiveJob`/Sidekiq)
`app/jobs/bot_runtime/transcribe_audio_job.rb`

- `perform(event, audio_file_url, agent_bot, conversation)` — `agent_bot`/`conversation` are passed as the real ActiveRecord objects (ActiveJob serializes them via GlobalID and reloads them for `perform`), not IDs, since `DelegationService#delegate` already holds both.
- Calls `AudioTranscriptionService.new(audio_file_url).call`.
- **Success**: sets `event[:message_content] = transcript` (event is the same hash `build_message_event` returns — symbol keys throughout, matching how `SendEventJob#perform` already reads it via `event[:conversation_id]`), enqueues `BotRuntime::SendEventJob.perform_later(event)` — same job/path a normal text message already takes.
- **Failure** (`TranscriptionError` rescued): does **not** enqueue `SendEventJob` at all — this turn never reaches the bot/LLM. Instead sends a deterministic fallback message directly to the customer via the existing `AgentBots::MessageCreator` service (already used by the price-gate release form — see `evocrm_vascaino_core_agent` memory): `AgentBots::MessageCreator.new(agent_bot).create_bot_reply(fallback_text, conversation, force: true)`. Fallback text: `"Não consegui entender o áudio, você pode escrever a mensagem?"`. Logs `[AudioTranscription] failed for conversation=<id>: <error>`.
- Rationale for bypassing the LLM on failure rather than feeding it an error marker: this codebase has repeatedly found prompt-only instructions unreliable under a confident model (documented at least 3 times in the price-gate and product-search sagas — see `evocrm_vascaino_core_agent` memory). A deterministic Rails-side send guarantees the exact fallback wording regardless of model behavior.

### 3. `BotRuntime::DelegationService#delegate` (edited)
`app/services/bot_runtime/delegation_service.rb`

- After building `event` via the existing `build_message_event` (unchanged), check `@message.attachments.find(&:audio?)` (idiomatic enum-generated predicate already on `Attachment`, no MIME-string sniffing needed).
  - **No audio attachment**: unchanged behavior — `SendEventJob.perform_later(event)` directly.
  - **Has audio attachment**: enqueue `BotRuntime::TranscribeAudioJob.perform_later(event, audio.file_url, @agent_bot, @conversation)` instead of `SendEventJob`.
- If a message somehow has more than one audio attachment, use the first one found (`.find`, not `.select`) — not worth extra complexity for a case that doesn't occur in real WhatsApp usage.

## Data flow

```
Evolution API webhook (voice note)
  → Rails ingests + stores attachment (existing, unchanged)
  → AgentBotListener#message_created → delegate_to_bot_runtime (existing, unchanged)
  → DelegationService#delegate
      no audio  → SendEventJob.perform_later(event)                      [unchanged path]
      has audio → TranscribeAudioJob.perform_later(event, file_url, agent_bot, conversation)
                     → AudioTranscriptionService (Groq call)
                         success → event[:message_content] = transcript → SendEventJob.perform_later(event)
                         failure → AgentBots::MessageCreator.new(agent_bot).create_bot_reply(fallback_text, conversation, force: true)
                                    (SendEventJob never runs this turn)
```

Enqueuing `TranscribeAudioJob` instead of calling Groq inline inside `delegate` keeps the original webhook request fast — `delegate` itself stays synchronous only for building the hash (as today), and the blocking network call moves fully into Sidekiq, same as the existing `SendEventJob` async boundary.

## Error handling

- `AudioTranscriptionService` raises a narrow `TranscriptionError` for: download failure, Groq non-2xx, timeout, or an empty/missing transcript field in the response. No silent swallowing.
- `TranscribeAudioJob` rescues only `TranscriptionError` (not `StandardError`) around the service call, so unrelated bugs (e.g. a typo in `MessageCreator` usage) still surface normally instead of being masked as "transcription failed."
- No retry logic for the Groq call itself (YAGNI — real WhatsApp voice notes are short, a single 30s-timeout attempt is enough; if this proves flaky in practice, add ActiveJob's standard retry mechanism then, not preemptively).

## Testing

- `AudioTranscriptionService`: unit tests mocking the Groq HTTP call — success returns transcript, non-2xx raises `TranscriptionError`, timeout raises `TranscriptionError`, empty transcript field raises `TranscriptionError`.
- `DelegationService#delegate`: two branches — message without audio attachment still enqueues `SendEventJob` directly (regression guard, existing behavior untouched); message with an audio attachment enqueues `TranscribeAudioJob` with the right `file_url`, not `SendEventJob`.
- `TranscribeAudioJob`: success path — mocks the service, asserts `SendEventJob.perform_later` is called with `message_content` replaced by the transcript. Failure path — mocks the service to raise, asserts `SendEventJob` is NOT enqueued, and `AgentBots::MessageCreator#create_bot_reply` is called with the exact fallback text and `force: true`.

## Out of scope

- Image support (separate future work, needs the Go/Python layers touched — see `evocrm_botruntime_and_media_gap` memory).
- Showing the transcript in the EvoCRM conversation UI for human attendants (explicitly declined by user — transcript is bot-internal only).
- Retry/backoff tuning for Groq calls (add later if real usage shows it's needed).
