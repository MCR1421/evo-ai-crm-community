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
