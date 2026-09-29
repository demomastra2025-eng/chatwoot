class Whatsapp::RecordingPacketOrder
  MAX_DUPLICATE_DELAY_NS = 120_000_000
  attr_reader :anchor, :duplicates, :reordered

  def initialize(budget:)
    @budget = budget
    @pending = {}
    @seen = {}
    @duplicates = @reordered = 0
  end

  def push(packet)
    item = packet_position(packet)
    sequence = item[2]
    return if duplicate?(item)

    fail_order! if @last_emitted && sequence <= @last_emitted
    @reordered += 1 if sequence < @highest
    @highest = [@highest, sequence].max
    @pending[sequence] = item
    emit_first { |ready| yield(*ready) } if @pending.size > Whatsapp::RecordingDecodeBudget::REORDER_PACKETS
  end

  def finish
    emit_first { |ready| yield(*ready) } until @pending.empty?
  end

  private

  def packet_position(packet)
    @anchor ||= packet
    @highest ||= packet.sequence
    fail_order! if packet.payload_type != @anchor.payload_type
    delta = signed_delta(packet.sequence, @highest & 0xffff, 16)
    sequence = @highest + delta
    ticks = signed_delta(packet.timestamp, @anchor.timestamp, 32)
    @budget.epoch_samples!(ticks.abs)
    [packet, ticks, sequence]
  end

  def signed_delta(value, reference, bits)
    modulus = 1 << bits
    delta = (value - reference) & (modulus - 1)
    fail_order! if delta == modulus / 2
    delta >= modulus / 2 ? delta - modulus : delta
  end

  def duplicate?(item)
    packet, ticks, sequence = item
    previous = @pending[sequence] || @seen[sequence]
    return false unless previous

    same_packet = previous[0].raw_sha256 == packet.raw_sha256 && previous[1] == ticks
    nearby_observation = (previous[0].offset_ns - packet.offset_ns).abs <= MAX_DUPLICATE_DELAY_NS
    fail_order! unless same_packet && nearby_observation
    @duplicates += 1
    true
  end

  def emit_first
    sequence = @pending.keys.min
    item = @pending.delete(sequence)
    yield item
    @last_emitted = sequence
    @seen[sequence] = item
    @seen.shift while @seen.size > Whatsapp::RecordingDecodeBudget::REORDER_PACKETS
  end

  def fail_order!
    raise Whatsapp::RecordingDecodeError, 'ambiguous_packet_order'
  end
end
