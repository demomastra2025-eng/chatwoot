# frozen_string_literal: true

class Accounts::HeavyRecordingsSnapshot
  MAX_RECORDINGS = 200

  def initialize(account_id:)
    @account_id = account_id
    @rows = []
  end

  def add(session:, byte_size:)
    return unless eligible?(byte_size)

    row = recording_row(session, byte_size)
    index = @rows.bsearch_index { |entry| entry[:byte_size] < byte_size } || @rows.size
    @rows.insert(index, row)
    @rows.pop if @rows.size > MAX_RECORDINGS
  rescue StandardError => e
    Rails.logger.warn("[HeavyRecordingsSnapshot] Could not link recording for account #{@account_id}: #{e.class.name}")
  end

  def recording_row(session, byte_size)
    {
      id: "call_#{session.id}",
      byte_size: byte_size,
      inbox_id: session.inbox_id,
      conversation_id: session.conversation_id,
      created_at: session.created_at&.iso8601,
      download_url: playback_url(session)
    }
  end

  def write!
    Redis::Alfred.set(cache_key, JSON.generate(recordings: @rows, updated_at: Time.current.iso8601))
  end

  def snapshot
    raw = Redis::Alfred.get(cache_key)
    JSON.parse(raw, symbolize_names: true) if raw
  rescue JSON::ParserError
    nil
  end

  private

  def eligible?(byte_size)
    byte_size.positive? && (@rows.size < MAX_RECORDINGS || byte_size > @rows.last[:byte_size])
  end

  def playback_url(session)
    Telephony::CallRecordingPlaybackUrl.path_for(session, storage_key: session.recording_ref)
  rescue StandardError
    nil
  end

  def cache_key
    "account:#{@account_id}:storage_heavy_recordings_v1"
  end
end
