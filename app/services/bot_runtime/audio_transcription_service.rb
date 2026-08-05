# frozen_string_literal: true

require 'net/http/post/multipart'
require 'tempfile'

module BotRuntime
  class AudioTranscriptionService
    class TranscriptionError < StandardError; end

    GROQ_URL = 'https://api.groq.com/openai/v1/audio/transcriptions'
    TIMEOUT = 30

    # Whisper's optional `prompt` param biases transcription toward this
    # vocabulary without constraining it - it's context, not a hard list.
    # Added 2026-08-05 after real incidents where short/unclear audio got
    # transcribed as an unrelated word ("Instator"/"Presidência" instead of
    # "Estator"/customer's actual request) - the shop only sells starter
    # motors and alternators (see the agent's own instruction), so biasing
    # toward that vocabulary should reduce (not guaranteed to eliminate,
    # Whisper hallucination is model-level noise) mis-hearing this kind of
    # audio as an unrelated word.
    CATALOG_PROMPT = 'Peças automotivas: alternador, motor de partida, ' \
                      'arranque, estator, rotor, induzido, regulador, ' \
                      'polia, bendix, solenoide, automático, presidente. ' \
                      'Marcas: Bosch, Valeo, Denso, Magneti Marelli, Hitachi.'

    EXTENSION_BY_CONTENT_TYPE = {
      'audio/ogg' => '.ogg',
      'audio/opus' => '.ogg',
      'audio/mp4' => '.m4a',
      'audio/mpeg' => '.mp3',
      'audio/wav' => '.wav'
    }.freeze

    def initialize(attachment)
      @attachment = attachment
    end

    def call
      tempfile = download_audio
      transcribe(tempfile)
    ensure
      tempfile&.close!
    end

    private

    # Downloads directly from ActiveStorage rather than via attachment.file_url:
    # that URL is generated for a human clicking it in a browser (localhost:3020,
    # the host-mapped port) and isn't reachable from inside a Sidekiq container.
    def download_audio
      tempfile = Tempfile.new(['audio', content_type_extension])
      tempfile.binmode
      @attachment.file.download { |chunk| tempfile.write(chunk) }
      tempfile.rewind
      tempfile
    rescue StandardError => e
      raise TranscriptionError, "download failed: #{e.message}"
    end

    def content_type
      @attachment.file.content_type
    end

    def content_type_extension
      EXTENSION_BY_CONTENT_TYPE.fetch(content_type, '.ogg')
    end

    def transcribe(tempfile)
      uri = URI.parse(GROQ_URL)
      upload = UploadIO.new(tempfile, content_type || 'audio/ogg', "audio#{content_type_extension}")

      request = Net::HTTP::Post::Multipart.new(
        uri.path,
        'file' => upload,
        'model' => 'whisper-large-v3',
        'language' => 'pt',
        'response_format' => 'json',
        'prompt' => CATALOG_PROMPT
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
