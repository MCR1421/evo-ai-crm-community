# Audio Transcription for vascaino_core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** WhatsApp voice notes reach `vascaino_core` as transcribed text instead of empty content, using Groq's Whisper API, with zero changes to the Go (`evo-bot-runtime`) or Python (`evo-ai-processor-community`) layers.

**Architecture:** `BotRuntime::DelegationService#delegate` detects an audio attachment on the incoming message and routes to a new `BotRuntime::TranscribeAudioJob` (Sidekiq) instead of enqueuing `BotRuntime::SendEventJob` directly. The job calls a new `BotRuntime::AudioTranscriptionService` (Net::HTTP multipart POST to Groq's OpenAI-compatible `/audio/transcriptions` endpoint), then either enqueues `SendEventJob` with the transcript as `message_content`, or — on transcription failure — sends a deterministic fallback message directly via the existing `AgentBots::MessageCreator`, bypassing the bot/LLM entirely for that turn.

**Tech Stack:** Ruby on Rails (evo-ai-crm-community), RSpec + WebMock for tests, `multipart-post` gem (already in `Gemfile.lock`) for the Groq multipart upload, `down` gem (already used elsewhere in this repo) for downloading the attachment bytes.

## Global Constraints

- Groq endpoint: `https://api.groq.com/openai/v1/audio/transcriptions`, `model: whisper-large-v3`, `language: pt`, `response_format: json`, 30s timeout — exact values from the retired n8n node, per the design spec.
- New env var `GROQ_API_KEY` — do NOT reuse the API key that was hardcoded in plaintext in the old n8n node (`docs/superpowers/specs/2026-08-05-audio-transcription-design.md`); a fresh key must be generated in Groq's console before this ships to production. Document as a manual pre-deploy step; do not put any real key value in code, `.env.example`, or commits.
- On transcription failure, the customer must receive exactly: `"Não consegui entender o áudio, você pode escrever a mensagem?"` — sent via `AgentBots::MessageCreator.new(agent_bot).create_bot_reply(text, conversation, force: true)`, and `SendEventJob` must NOT be enqueued that turn.
- No retry logic for the Groq HTTP call itself (YAGNI per spec — add later only if real usage shows it's needed).
- `event` hashes use symbol keys throughout (matches `BotRuntime::SendEventJob#perform`'s existing `event[:conversation_id]` access — ActiveJob's Arguments serializer preserves symbol vs. string keys across Sidekiq (de)serialization).
- Spec doc: `docs/superpowers/specs/2026-08-05-audio-transcription-design.md` (commit `d8c83eb`) — read it if any task instruction here seems to conflict; this plan implements it exactly.

---

## Task 1: `BotRuntime::AudioTranscriptionService`

**Files:**
- Create: `app/services/bot_runtime/audio_transcription_service.rb`
- Test: `spec/services/bot_runtime/audio_transcription_service_spec.rb`
- Modify: `.env.example` (append `GROQ_API_KEY=` under the existing `EVOAI_CRM_API_TOKEN=` line at line 258, no value)

**Interfaces:**
- Consumes: nothing from other tasks (first task).
- Produces: `BotRuntime::AudioTranscriptionService.new(audio_file_url, content_type).call` → returns a transcript `String` on success, raises `BotRuntime::AudioTranscriptionService::TranscriptionError` (a `StandardError` subclass) on any failure. `content_type` is the attachment's MIME type (e.g. `"audio/ogg"`), used only to pick a file extension for the multipart upload — pass `nil` to fall back to `.ogg`. Task 2 depends on this exact class name, method name, and error class.

- [ ] **Step 1: Write the failing test for the success path**

Create `spec/services/bot_runtime/audio_transcription_service_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe BotRuntime::AudioTranscriptionService do
  let(:file_url) { 'https://cdn.example.com/audio/note.ogg' }
  let(:groq_endpoint) { 'https://api.groq.com/openai/v1/audio/transcriptions' }
  let(:tempfile) do
    file = Tempfile.new(['note', '.ogg'])
    file.binmode
    file.write('fake audio bytes')
    file.rewind
    file
  end

  before do
    ENV['GROQ_API_KEY'] = 'test-groq-key'
    allow(Down).to receive(:download).with(file_url).and_return(tempfile)
  end

  after { tempfile.close! }

  describe '#call' do
    it 'returns the transcript text on a successful Groq response' do
      stub_request(:post, groq_endpoint)
        .with(headers: { 'Authorization' => 'Bearer test-groq-key' })
        .to_return(
          status: 200,
          body: { text: 'quanto custa o alternador do gol g5' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = described_class.new(file_url, 'audio/ogg').call

      expect(result).to eq('quanto custa o alternador do gol g5')
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/services/bot_runtime/audio_transcription_service_spec.rb`
Expected: FAIL with `uninitialized constant BotRuntime::AudioTranscriptionService`

- [ ] **Step 3: Implement the service**

Create `app/services/bot_runtime/audio_transcription_service.rb`:

```ruby
# frozen_string_literal: true

require 'net/http/post/multipart'
require 'down'

module BotRuntime
  class AudioTranscriptionService
    class TranscriptionError < StandardError; end

    GROQ_URL = 'https://api.groq.com/openai/v1/audio/transcriptions'
    TIMEOUT = 30

    EXTENSION_BY_CONTENT_TYPE = {
      'audio/ogg' => '.ogg',
      'audio/opus' => '.ogg',
      'audio/mp4' => '.m4a',
      'audio/mpeg' => '.mp3',
      'audio/wav' => '.wav'
    }.freeze

    def initialize(audio_file_url, content_type = nil)
      @audio_file_url = audio_file_url
      @content_type = content_type
    end

    def call
      tempfile = download_audio
      transcribe(tempfile)
    ensure
      tempfile&.close
    end

    private

    def download_audio
      Down.download(@audio_file_url)
    rescue Down::Error => e
      raise TranscriptionError, "download failed: #{e.message}"
    end

    def transcribe(tempfile)
      uri = URI.parse(GROQ_URL)
      extension = EXTENSION_BY_CONTENT_TYPE.fetch(@content_type, '.ogg')
      upload = UploadIO.new(tempfile, @content_type || 'audio/ogg', "audio#{extension}")

      request = Net::HTTP::Post::Multipart.new(
        uri.path,
        'file' => upload,
        'model' => 'whisper-large-v3',
        'language' => 'pt',
        'response_format' => 'json'
      )
      request['Authorization'] = "Bearer #{ENV.fetch('GROQ_API_KEY', nil)}"

      response = perform_request(uri, request)
      parse_response(response)
    end

    def perform_request(uri, request)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.request(request)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise TranscriptionError, "request failed: #{e.message}"
    end

    def parse_response(response)
      unless response.is_a?(Net::HTTPSuccess)
        raise TranscriptionError, "Groq responded #{response.code}: #{response.body}"
      end

      text = JSON.parse(response.body)['text']
      raise TranscriptionError, 'empty transcript in Groq response' if text.blank?

      text
    rescue JSON::ParserError => e
      raise TranscriptionError, "invalid Groq response: #{e.message}"
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/services/bot_runtime/audio_transcription_service_spec.rb`
Expected: PASS (1 example)

- [ ] **Step 5: Write failing tests for the error paths**

Append to the `describe '#call'` block in the same spec file:

```ruby
    it 'raises TranscriptionError when the download fails' do
      allow(Down).to receive(:download).with(file_url).and_raise(Down::Error, 'timeout')

      expect { described_class.new(file_url, 'audio/ogg').call }
        .to raise_error(BotRuntime::AudioTranscriptionService::TranscriptionError, /download failed/)
    end

    it 'raises TranscriptionError when Groq responds with a non-2xx status' do
      stub_request(:post, groq_endpoint).to_return(status: 500, body: 'internal error')

      expect { described_class.new(file_url, 'audio/ogg').call }
        .to raise_error(BotRuntime::AudioTranscriptionService::TranscriptionError, /Groq responded 500/)
    end

    it 'raises TranscriptionError when Groq returns an empty transcript' do
      stub_request(:post, groq_endpoint)
        .to_return(status: 200, body: { text: '' }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect { described_class.new(file_url, 'audio/ogg').call }
        .to raise_error(BotRuntime::AudioTranscriptionService::TranscriptionError, /empty transcript/)
    end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bundle exec rspec spec/services/bot_runtime/audio_transcription_service_spec.rb`
Expected: PASS (4 examples)

- [ ] **Step 7: Add the `GROQ_API_KEY` placeholder to `.env.example`**

In `.env.example`, find line 258 (`EVOAI_CRM_API_TOKEN=`) and add immediately after it:

```
GROQ_API_KEY=
```

- [ ] **Step 8: Commit**

```bash
git add app/services/bot_runtime/audio_transcription_service.rb spec/services/bot_runtime/audio_transcription_service_spec.rb .env.example
git commit -m "feat: add Groq Whisper transcription service for voice notes"
```

---

## Task 2: `BotRuntime::TranscribeAudioJob`

**Files:**
- Create: `app/jobs/bot_runtime/transcribe_audio_job.rb`
- Test: `spec/jobs/bot_runtime/transcribe_audio_job_spec.rb`

**Interfaces:**
- Consumes: `BotRuntime::AudioTranscriptionService.new(url, content_type).call` (Task 1) and `BotRuntime::SendEventJob.perform_later(event)` (existing, `app/jobs/bot_runtime/send_event_job.rb`) and `AgentBots::MessageCreator.new(agent_bot).create_bot_reply(text, conversation, force:)` (existing, `app/services/agent_bots/message_creator.rb`).
- Produces: `BotRuntime::TranscribeAudioJob.perform_later(event, audio_file_url, content_type, agent_bot, conversation)`. Task 3 depends on this exact argument order and that `agent_bot`/`conversation` are passed as ActiveRecord objects (not IDs).

- [ ] **Step 1: Write the failing test for the success path**

Create `spec/jobs/bot_runtime/transcribe_audio_job_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::TranscribeAudioJob do
  let(:account) { create(:account) }
  let(:agent_bot) { create(:agent_bot, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:event) { { conversation_id: conversation.display_id, agent_bot_id: agent_bot.id, message_content: '' } }
  let(:audio_file_url) { 'https://cdn.example.com/audio/note.ogg' }

  describe '#perform' do
    it 'sets message_content to the transcript and enqueues SendEventJob on success' do
      service_double = instance_double(BotRuntime::AudioTranscriptionService, call: 'quanto custa o alternador')
      allow(BotRuntime::AudioTranscriptionService).to receive(:new)
        .with(audio_file_url, 'audio/ogg').and_return(service_double)

      expect(BotRuntime::SendEventJob).to receive(:perform_later) do |sent_event|
        expect(sent_event[:message_content]).to eq('quanto custa o alternador')
        expect(sent_event[:conversation_id]).to eq(conversation.display_id)
      end

      described_class.new.perform(event, audio_file_url, 'audio/ogg', agent_bot, conversation)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/jobs/bot_runtime/transcribe_audio_job_spec.rb`
Expected: FAIL with `uninitialized constant BotRuntime::TranscribeAudioJob`

- [ ] **Step 3: Implement the job**

Create `app/jobs/bot_runtime/transcribe_audio_job.rb`:

```ruby
# frozen_string_literal: true

module BotRuntime
  class TranscribeAudioJob < ApplicationJob
    queue_as :bot_runtime

    FALLBACK_TEXT = 'Não consegui entender o áudio, você pode escrever a mensagem?'

    def perform(event, audio_file_url, content_type, agent_bot, conversation)
      transcript = AudioTranscriptionService.new(audio_file_url, content_type).call

      event[:message_content] = transcript
      SendEventJob.perform_later(event)

      Rails.logger.info "[AudioTranscription] transcribed for conversation=#{conversation.display_id}"
    rescue AudioTranscriptionService::TranscriptionError => e
      Rails.logger.error "[AudioTranscription] failed for conversation=#{conversation.display_id}: #{e.message}"
      AgentBots::MessageCreator.new(agent_bot).create_bot_reply(FALLBACK_TEXT, conversation, force: true)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/jobs/bot_runtime/transcribe_audio_job_spec.rb`
Expected: PASS (1 example)

- [ ] **Step 5: Write the failing test for the failure path**

Append to the `describe '#perform'` block:

```ruby
    it 'sends the deterministic fallback and does not enqueue SendEventJob when transcription fails' do
      service_double = instance_double(BotRuntime::AudioTranscriptionService)
      allow(BotRuntime::AudioTranscriptionService).to receive(:new)
        .with(audio_file_url, 'audio/ogg').and_return(service_double)
      allow(service_double).to receive(:call)
        .and_raise(BotRuntime::AudioTranscriptionService::TranscriptionError, 'Groq responded 500')

      expect(BotRuntime::SendEventJob).not_to receive(:perform_later)

      creator_double = instance_double(AgentBots::MessageCreator)
      allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator_double)
      expect(creator_double).to receive(:create_bot_reply)
        .with(described_class::FALLBACK_TEXT, conversation, force: true)

      described_class.new.perform(event, audio_file_url, 'audio/ogg', agent_bot, conversation)
    end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bundle exec rspec spec/jobs/bot_runtime/transcribe_audio_job_spec.rb`
Expected: PASS (2 examples)

- [ ] **Step 7: Commit**

```bash
git add app/jobs/bot_runtime/transcribe_audio_job.rb spec/jobs/bot_runtime/transcribe_audio_job_spec.rb
git commit -m "feat: add TranscribeAudioJob to route voice notes through Groq before dispatch"
```

---

## Task 3: Route audio messages through `TranscribeAudioJob` in `DelegationService`

**Files:**
- Modify: `app/services/bot_runtime/delegation_service.rb:11-17` (the `delegate` method)
- Test: `spec/services/bot_runtime/delegation_service_spec.rb` (new file — no existing spec for this service)

**Interfaces:**
- Consumes: `BotRuntime::TranscribeAudioJob.perform_later(event, url, content_type, agent_bot, conversation)` (Task 2, exact signature) and `BotRuntime::SendEventJob.perform_later(event)` (existing, unchanged).
- Produces: nothing further downstream — this is the last task, it wires the two prior pieces into the real message flow.

- [ ] **Step 1: Write the failing test for the no-audio (regression) path**

Create `spec/services/bot_runtime/delegation_service_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::DelegationService do
  let(:account) { create(:account) }
  let(:agent_bot) { create(:agent_bot, account: account, outgoing_url: 'https://bot.example.com/webhook') }
  let(:conversation) { create(:conversation, account: account) }

  describe '#delegate' do
    context 'when the message has no audio attachment' do
      let(:message) { create(:message, conversation: conversation, content: 'oi, tem alternador?') }

      it 'enqueues SendEventJob directly' do
        expect(BotRuntime::SendEventJob).to receive(:perform_later) do |event|
          expect(event[:message_content]).to eq('oi, tem alternador?')
        end
        expect(BotRuntime::TranscribeAudioJob).not_to receive(:perform_later)

        described_class.new(agent_bot, message, conversation).delegate
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails or passes for the wrong reason**

Run: `bundle exec rspec spec/services/bot_runtime/delegation_service_spec.rb`
Expected: This should already PASS against the current, unmodified `delegate` method (it only exercises existing behavior) — confirms the regression baseline before the edit. If it fails, stop and investigate the factories (`agent_bot`, `conversation`, `message`) before proceeding; do not edit `delegation_service.rb` until this baseline is green.

- [ ] **Step 3: Write the failing test for the audio path**

Append inside the `describe '#delegate'` block:

```ruby
    context 'when the message has an audio attachment' do
      let(:message) { create(:message, conversation: conversation, content: '') }

      before do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new('fake audio bytes'),
          filename: 'note.ogg',
          content_type: 'audio/ogg'
        )
        attachment = message.attachments.build(file_type: 'audio')
        attachment.file.attach(blob)
        message.save!
      end

      it 'enqueues TranscribeAudioJob instead of SendEventJob' do
        expect(BotRuntime::SendEventJob).not_to receive(:perform_later)
        expect(BotRuntime::TranscribeAudioJob).to receive(:perform_later) do |event, url, content_type, bot, conv|
          expect(event[:conversation_id]).to eq(conversation.display_id)
          expect(url).to be_present
          expect(content_type).to eq('audio/ogg')
          expect(bot).to eq(agent_bot)
          expect(conv).to eq(conversation)
        end

        described_class.new(agent_bot, message, conversation).delegate
      end
    end
```

- [ ] **Step 4: Run the test to verify the new example fails**

Run: `bundle exec rspec spec/services/bot_runtime/delegation_service_spec.rb`
Expected: FAIL — `TranscribeAudioJob` never receives `perform_later` because `delegate` doesn't check for audio attachments yet (the first context's example still passes).

- [ ] **Step 5: Edit `delegate` in `delegation_service.rb`**

In `app/services/bot_runtime/delegation_service.rb`, replace lines 11-17:

```ruby
    def delegate
      event = build_message_event
      BotRuntime::SendEventJob.perform_later(event)

      Rails.logger.info "[BotRuntime::DelegationService] Event enqueued: " \
                        "conversation=#{@conversation.display_id} bot=#{@agent_bot.name}"
    end
```

with:

```ruby
    def delegate
      event = build_message_event
      audio_attachment = @message.attachments.find(&:audio?)

      if audio_attachment
        BotRuntime::TranscribeAudioJob.perform_later(
          event, audio_attachment.file_url, audio_attachment.file.content_type, @agent_bot, @conversation
        )
        Rails.logger.info "[BotRuntime::DelegationService] Audio message routed to transcription: " \
                          "conversation=#{@conversation.display_id} bot=#{@agent_bot.name}"
      else
        BotRuntime::SendEventJob.perform_later(event)
        Rails.logger.info "[BotRuntime::DelegationService] Event enqueued: " \
                          "conversation=#{@conversation.display_id} bot=#{@agent_bot.name}"
      end
    end
```

- [ ] **Step 6: Run both tests to verify they pass**

Run: `bundle exec rspec spec/services/bot_runtime/delegation_service_spec.rb`
Expected: PASS (2 examples)

- [ ] **Step 7: Run the full BotRuntime test slice to catch regressions**

Run: `bundle exec rspec spec/services/bot_runtime/ spec/jobs/bot_runtime/`
Expected: PASS, all examples (this task's 2 + Task 1's 4 + Task 2's 2)

- [ ] **Step 8: Commit**

```bash
git add app/services/bot_runtime/delegation_service.rb spec/services/bot_runtime/delegation_service_spec.rb
git commit -m "feat: route WhatsApp voice notes through Groq transcription before reaching the bot"
```

---

## Post-implementation manual verification (not automated — do after Task 3)

1. Set a real `GROQ_API_KEY` in the container's env (fresh key, not the one exposed in the old n8n node — see Global Constraints).
2. Restart the Rails/Sidekiq processes so the new job class and env var are loaded.
3. Send a real WhatsApp voice note asking something like "tem alternador do gol g5?" to the connected number.
4. Confirm in `evo-ai-crm-community` logs: a `[BotRuntime::DelegationService] Audio message routed to transcription` line, followed by `[AudioTranscription] transcribed for conversation=...`.
5. Confirm the bot's reply in WhatsApp responds to the actual audio content (proves the transcript reached the LLM), not a generic fallback.
6. Separately, send a voice note while `GROQ_API_KEY` is temporarily unset/invalid (or Groq is unreachable) to confirm the fallback message ("Não consegui entender o áudio...") is sent and the conversation does NOT show a generic/unrelated bot reply.
