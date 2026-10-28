# frozen_string_literal: true

# Run with bundle exec rails runner script/onelink/backfill_call_transcripts.rb
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
scope = Telephony::CallSession.where("recording_ref IS NOT NULL OR metadata ? 'recording'")
account_ids = ENV.fetch('ACCOUNT_IDS', '').split(',').map(&:strip).reject(&:blank?)
scope = scope.where(account_id: account_ids.map { |id| Integer(id, 10) }) if account_ids.any?
limit = Integer(ENV['LIMIT'], 10) if ENV['LIMIT'].present?
raise ArgumentError, 'LIMIT must be positive' if limit && !limit.positive?

dry_run = ENV['DRY_RUN'] == '1'
force = ENV['FORCE'] == '1'
rate = ENV['COST_PER_AUDIO_MINUTE_USD']&.to_f
counts = { scanned: 0, mono: 0, stereo: 0, unknown_channels: 0, succeeded: 0, skipped: 0, failed: 0 }
channel_counts = { 1 => :mono, 2 => :stereo }.freeze
duration_seconds = 0.0

scope = scope.order(:id)
scope = scope.limit(limit) if limit
scope.each do |call_session|
  counts[:scanned] += 1
  transcription = call_session.metadata.to_h.dig('recording', 'transcription').to_h
  complete = transcription['status'] == 'completed' && transcription['transcript_items'].present? && transcription['summary'].present?
  if !dry_run && (complete || (transcription['status'] == 'completed' && !force))
    counts[:skipped] += 1
    next
  end

  service = Telephony::CallRecordingTranscriptionService.new(call_session, force: force)
  path = nil
  staged = false
  begin
    path, staged = service.send(:resolve_recording_file!)
    probe = Telephony::CallTranscript.probe(path)
    counts[channel_counts.fetch(probe['channels'], :unknown_channels)] += 1
    duration_seconds += probe['duration_seconds'].to_f
    if dry_run
      counts[:succeeded] += 1
    else
      result = service.perform
      counts[result[:success] ? :succeeded : :failed] += 1
    end
  rescue StandardError => e
    counts[:failed] += 1
    Rails.logger.warn("Call transcript backfill failed call_session_id=#{call_session.id} error_class=#{e.class.name}")
  ensure
    FileUtils.rm_f(path) if staged && path.present?
  end
end

puts JSON.generate(counts.merge(
                     dry_run: dry_run,
                     duration_seconds: duration_seconds.round(1),
                     estimated_cost_usd: rate ? (duration_seconds / 60 * rate).round(2) : nil,
                     elapsed_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
                   ))
