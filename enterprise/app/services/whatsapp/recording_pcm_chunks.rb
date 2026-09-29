class Whatsapp::RecordingPcmChunks
  attr_reader :chunks

  def initialize(dir:, budget:, capacity: Whatsapp::RecordingWavChunk::CAPACITY)
    valid = capacity.is_a?(Integer) && capacity.between?(1, Whatsapp::RecordingWavChunk::CAPACITY)
    raise ArgumentError, 'Invalid chunk capacity' unless valid

    @dir = dir
    @budget = budget
    @capacity = capacity
    @chunks = []
  end

  def start_epoch(descriptor:, origin_ns:)
    raise ArgumentError, 'Previous epoch is still open' if @current

    @descriptor = descriptor
    @origin_ns = origin_ns
    @epoch_samples = 0
  end

  def write(pcm, samples, gap: false)
    consumed = 0
    while consumed < samples
      start_chunk unless @current
      count = [samples - consumed, @current.remaining].min
      @current.write(pcm.byteslice(consumed * 4, count * 4), count, gap: gap)
      consumed += count
      @epoch_samples += count
      finish_chunk if @current.remaining.zero?
    end
  end

  def finish_epoch
    finish_chunk if @current
  end

  def close
    @current&.close
  end

  private

  def start_chunk
    @budget.charge!(:chunks)
    id = format('chunk_%06d', @chunks.size + 1)
    descriptor = @descriptor.merge('id' => id, 'format' => 'pcm_s16le_wav')
    @current = Whatsapp::RecordingWavChunk.new(path: File.join(@dir, "#{id}.wav"), descriptor: descriptor,
                                               timing: { start_sample: @epoch_samples, origin_ns: @origin_ns }, budget: @budget, capacity: @capacity)
  end

  def finish_chunk
    @chunks << @current.finish
    @current = nil
  end
end
