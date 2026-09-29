class Whatsapp::RecordingEpochDecoder
  RATE = Whatsapp::RecordingDecodeBudget::SAMPLE_RATE

  def initialize(epoch:, sink:, budget:, decoder_factory: -> { Whatsapp::NativeOpusDecoder.new })
    @epoch = epoch
    @sink = sink
    @budget = budget
    @decoder_factory = decoder_factory
    @order = Whatsapp::RecordingPacketOrder.new(budget: budget)
    @cursor = @decoded_samples = @decoded_packets = 0
    @packet_channels = []
  end

  def perform
    @decoder = @decoder_factory.call
    yield ->(packet) { @order.push(packet) { |*ready| decode_packet(*ready) } }
    @order.finish { |*ready| decode_packet(*ready) }
    raise Whatsapp::RecordingDecodeError, 'empty_epoch' unless @decoded_packets.positive?

    @sink.finish_epoch
    summary
  rescue Whatsapp::NativeOpusDecoder::InvalidPacket => e
    raise Whatsapp::RecordingDecodeError, e.message
  ensure
    @decoder&.close
  end

  private

  def decode_packet(packet, ticks, sequence)
    start_epoch(ticks) unless @start_tick
    position = ticks - @start_tick
    @budget.epoch_samples!(position)
    validate_progression(packet, ticks, position, sequence)
    fill_gap(position - @cursor)
    frame = @decoder.decode(packet.payload)
    @budget.epoch_samples!(position + frame.samples)
    @sink.write(frame.pcm, frame.samples)
    @packet_channels |= [frame.packet_channels]
    @cursor = position + frame.samples
    @last_sequence = sequence
    @decoded_packets += 1
    @decoded_samples += frame.samples
  end

  def start_epoch(ticks)
    @start_tick = ticks
    @origin_ns = @order.anchor.offset_ns + (ticks * 1_000_000_000 / RATE)
    raise Whatsapp::RecordingDecodeError, 'invalid_epoch_origin' if @origin_ns.negative?

    descriptor = @epoch.slice('side', 'source_kind', 'generation', 'ssrc').merge('epoch_id' => @epoch['id'])
    @sink.start_epoch(descriptor: descriptor, origin_ns: @origin_ns)
  end

  def validate_progression(packet, ticks, position, sequence)
    raise Whatsapp::RecordingDecodeError, 'overlapping_rtp_clock' if position < @cursor
    raise Whatsapp::RecordingDecodeError, 'ambiguous_sequence_gap' if @last_sequence && sequence > @last_sequence + 1 && position == @cursor

    predicted = @order.anchor.offset_ns + (ticks * 1_000_000_000 / RATE)
    skew = (packet.offset_ns - predicted).abs
    raise Whatsapp::RecordingDecodeError, 'ambiguous_observed_clock' if skew > Whatsapp::RecordingDecodeBudget::MAX_CLOCK_SKEW_NS
  end

  def fill_gap(samples)
    raise Whatsapp::RecordingDecodeError, 'unsupported_gap_size' unless (samples % 120).zero?

    while samples.positive?
      count = [samples, Whatsapp::NativeOpusDecoder::MAX_SAMPLES].min
      @decoder.conceal(count)
      @sink.write("\0".b * (count * 4), count, gap: true)
      @cursor += count
      samples -= count
    end
  end

  def summary
    { 'id' => @epoch['id'], 'side' => @epoch['side'], 'source_kind' => @epoch['source_kind'], 'generation' => @epoch['generation'],
      'ssrc' => @epoch['ssrc'], 'artifact_ids' => @epoch['artifacts'].pluck('id'), 'continuity_reason' => @epoch['continuity_reason'],
      'anchor_rtp_timestamp' => @order.anchor.timestamp, 'anchor_observed_offset_ns' => @order.anchor.offset_ns,
      'first_decoded_rtp_delta' => @start_tick, 'origin_offset_ns' => @origin_ns, 'end_offset_ns' => @origin_ns + (@cursor * 1_000_000_000 / RATE),
      'timeline_samples' => @cursor, 'decoded_samples' => @decoded_samples, 'decoded_packets' => @decoded_packets,
      'duplicate_packets_dropped' => @order.duplicates, 'reordered_packets' => @order.reordered,
      'packet_channels' => @packet_channels.sort, 'output_channels' => 2, 'decoder_version' => @decoder.version }
  end
end
