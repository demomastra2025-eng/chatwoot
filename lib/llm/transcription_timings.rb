# frozen_string_literal: true

# Logs only stage timings and an ephemeral correlation id; never logs audio, account data or credentials.
class Llm::TranscriptionTimings
  def initialize(source:)
    @source = source
    @run_id = SecureRandom.hex(6)
    @started_at = monotonic_time
  end

  def measure(stage)
    started_at = monotonic_time
    result = yield
    log(stage, started_at, 'ok')
    result
  rescue StandardError
    log(stage, started_at, 'error') if started_at
    raise
  end

  def mark(stage)
    log(stage, monotonic_time, 'started')
  end

  private

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def log(stage, started_at, status)
    finished_at = monotonic_time
    Rails.logger.info(
      "audio_transcription_stage source=#{@source} run_id=#{@run_id} stage=#{stage} " \
      "duration_ms=#{((finished_at - started_at) * 1000).round(1)} " \
      "elapsed_ms=#{((finished_at - @started_at) * 1000).round(1)} status=#{status}"
    )
  end
end
