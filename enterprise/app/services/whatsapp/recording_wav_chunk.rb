require 'digest'

class Whatsapp::RecordingWavChunk
  RATE = Whatsapp::RecordingDecodeBudget::SAMPLE_RATE
  CHANNELS = Whatsapp::RecordingDecodeBudget::CHANNELS
  CAPACITY = RATE * 15

  attr_reader :samples

  def initialize(path:, descriptor:, timing:, budget:, capacity: CAPACITY)
    @path = path
    @descriptor = descriptor
    @start_sample = timing.fetch(:start_sample)
    @origin_ns = timing.fetch(:origin_ns)
    @budget = budget
    @capacity = capacity
    @samples = 0
    @gaps = []
    @file = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
    @file.binmode
    @budget.charge!(:output_bytes, 44)
    raise Whatsapp::RecordingDecodeError, 'output_write_failed' unless @file.write("\0".b * 44) == 44
  rescue StandardError, NoMemoryError
    close
    raise
  end

  def remaining
    @capacity - @samples
  end

  def write(pcm, samples, gap:)
    valid = samples.is_a?(Integer) && samples.between?(1, remaining) && pcm.bytesize == samples * CHANNELS * 2
    raise ArgumentError, 'Invalid PCM chunk write' unless valid

    @budget.charge!(:output_bytes, pcm.bytesize)
    append_gap(samples) if gap
    raise Whatsapp::RecordingDecodeError, 'output_write_failed' unless @file.write(pcm) == pcm.bytesize

    @samples += samples
  end

  def finish
    @file.rewind
    raise Whatsapp::RecordingDecodeError, 'output_write_failed' unless @file.write(wav_header) == 44

    @file.flush
    @file.fsync
    @file.close
    @descriptor.merge('path' => @path, 'sample_rate' => RATE, 'channels' => CHANNELS, 'sample_count' => @samples,
                      'epoch_start_sample' => @start_sample, 'start_offset_ns' => offset(@start_sample),
                      'end_offset_ns' => offset(@start_sample + @samples), 'gap_ranges' => @gaps,
                      'byte_size' => File.size(@path), 'sha256' => Digest::SHA256.file(@path).hexdigest)
  end

  def close
    @file&.close unless @file&.closed?
  end

  private

  def append_gap(samples)
    if @gaps.last && @gaps.last['end_sample'] == @samples
      @gaps.last['end_sample'] += samples
    else
      @budget.charge!(:gap_ranges)
      @gaps << { 'start_sample' => @samples, 'end_sample' => @samples + samples, 'reason' => 'unobserved_rtp_audio' }
    end
  end

  def offset(sample)
    @origin_ns + (sample * 1_000_000_000 / RATE)
  end

  def wav_header
    bytes = @samples * CHANNELS * 2
    'RIFF'.b + [bytes + 36].pack('V') + 'WAVEfmt '.b + [16, 1, CHANNELS, RATE, RATE * CHANNELS * 2, CHANNELS * 2, 16].pack('VvvVVvv') +
      'data'.b + [bytes].pack('V')
  end
end
