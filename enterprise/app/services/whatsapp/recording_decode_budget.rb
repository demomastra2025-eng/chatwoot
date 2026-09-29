class Whatsapp::RecordingDecodeBudget
  CONTRACT = 'opus_pcm_mapping_v1'.freeze
  SAMPLE_RATE = 48_000
  CHANNELS = 2
  REORDER_PACKETS = 128
  MAX_CLOCK_SKEW_NS = 5_000_000_000
  CEILINGS = { packets: 500_000, output_bytes: 512 * 1024 * 1024, epoch_samples: SAMPLE_RATE * 3600,
               chunks: 512, gap_ranges: 4096, mapping_bytes: 16 * 1024 * 1024, seconds: 120 }.freeze

  def initialize(limits: {})
    valid = limits.all? { |key, value| CEILINGS.key?(key) && value.is_a?(Integer) && value.between?(1, CEILINGS[key]) }
    raise ArgumentError, 'Decode limits may only lower the fixed ceilings' unless valid

    @limits = CEILINGS.merge(limits)
    @counts = Hash.new(0)
    @started = monotonic_now
  end

  def check!
    raise Whatsapp::RecordingDecodeError, 'time_limit' if monotonic_now - @started > @limits[:seconds]
  end

  def charge!(key, amount = 1)
    check!
    raise ArgumentError, 'Invalid decode budget charge' unless amount.is_a?(Integer) && amount >= 0 && @limits.key?(key)

    @counts[key] += amount
    raise Whatsapp::RecordingDecodeError, "#{key}_limit" if @counts[key] > @limits[key]
  end

  def epoch_samples!(samples)
    check!
    raise Whatsapp::RecordingDecodeError, 'epoch_duration_limit' unless samples.is_a?(Integer) && samples.between?(0, @limits[:epoch_samples])
  end

  def mapping!(bytes)
    check!
    raise Whatsapp::RecordingDecodeError, 'mapping_size_limit' if bytes > @limits[:mapping_bytes]
  end

  private

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
