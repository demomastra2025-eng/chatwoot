require 'fiddle'
require 'digest'
require 'stringio'

# All audio in these specs is generated in-process; no customer recordings,
# network, provider or externally stored fixtures are used.
module WhatsappOpusFixtures
  def synthetic_opus_packets(durations: Array.new(20, 960), channels: 1, frequency: 700, **rtp)
    handle = Fiddle.dlopen('libopus.so.0')
    create = opus_fixture_function(handle, 'opus_encoder_create', [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP],
                                   Fiddle::TYPE_VOIDP)
    encode = opus_fixture_function(handle, 'opus_encode',
                                   [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
    destroy = opus_fixture_function(handle, 'opus_encoder_destroy', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
    error = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT, Fiddle::RUBY_FREE)
    encoder = create.call(48_000, channels, 2049, error)
    raise 'Synthetic encoder allocation failed' if encoder.null? || error[0, Fiddle::SIZEOF_INT].unpack1('i!') != 0

    options = { durations: durations, channels: channels, timestamp: 0, sequence: 1, ssrc: 1234, frequency: frequency }.merge(rtp)
    synthetic_encoded_packets(encoder, encode, options)
  ensure
    destroy&.call(encoder) if encoder && !encoder.null?
    error&.call_free
  end

  def opus_fixture_function(handle, name, arguments, result)
    Fiddle::Function.new(handle[name], arguments, result)
  end

  def synthetic_encoded_packets(encoder, encode, options)
    cursor = 0
    options[:durations].each_with_index.map do |samples, index|
      signal = Array.new(samples) { |sample| (8000 * Math.sin(2 * Math::PI * options[:frequency] * (cursor + sample) / 48_000)).to_i }
      payload = encode_fixture_payload(encoder, encode, signal, options[:channels])
      header = fixture_rtp_header(options, index, cursor)
      cursor += samples
      header + payload
    end
  end

  def encode_fixture_payload(encoder, encode, signal, channels)
    pcm = signal.flat_map { |value| Array.new(channels, value) }.pack('s!*')
    input = Fiddle::Pointer.malloc(pcm.bytesize, Fiddle::RUBY_FREE)
    output = Fiddle::Pointer.malloc(4000, Fiddle::RUBY_FREE)
    input[0, pcm.bytesize] = pcm
    size = encode.call(encoder, input, signal.size, output, 4000)
    raise 'Synthetic encode failed' unless size.between?(1, 4000)

    output[0, size]
  ensure
    input&.call_free
    output&.call_free
  end

  def fixture_rtp_header(options, index, cursor)
    [0x80, 111, (options[:sequence] + index) & 0xffff, (options[:timestamp] + cursor) & 0xffffffff, options[:ssrc]].pack('CCnNN')
  end

  def synthetic_full_rtp_header(packet)
    sequence, timestamp, ssrc = packet.byteslice(2, 10).unpack('nNN')
    [0xb2, 0xef, sequence, timestamp, ssrc].pack('CCnNN') + [42, 43].pack('NN') +
      [0xbede, 1].pack('nn') + "\x10\xab\0\0".b + packet.byteslice(12..) + "\0\0\0\x04".b
  end

  def synthetic_capture(packets, offsets: nil, origin_ns: 400_000_000)
    offsets ||= packets.map.with_index { |_packet, index| origin_ns + (index * 20_000_000) }
    "OLRTP1\n".b + packets.zip(offsets).map { |packet, offset| [offset, packet.bytesize].pack('Q>L>') + packet }.join.b
  end

  def synthetic_capture_artifact(packets, data:, **options)
    options = { id: 'track_000001', side: 'customer', generation: 1, reason: 'source_start' }.merge(options)
    offsets = options[:offsets] || packets.map.with_index { |_packet, index| 400_000_000 + (index * 20_000_000) }
    provenance = { 'id' => options[:id], 'format' => 'rtp_framed_v1', 'side' => options[:side],
                   'source_kind' => options[:side] == 'customer' ? 'meta' : 'browser', 'generation' => options[:generation],
                   'codec' => 'audio/opus', 'clock_rate' => 48_000, 'continuity_reason' => options[:reason] }
    provenance.merge(fixture_capture_clocks(packets, offsets)).merge('byte_size' => data.bytesize, 'sha256' => Digest::SHA256.hexdigest(data))
  end

  def fixture_capture_clocks(packets, offsets)
    { 'ssrc' => packets.first.byteslice(8, 4).unpack1('N'),
      'first_offset_ns' => offsets.min, 'last_offset_ns' => offsets.max, 'first_rtp_timestamp' => packets.first.byteslice(4, 4).unpack1('N'),
      'last_rtp_timestamp' => packets.last.byteslice(4, 4).unpack1('N'), 'packets' => packets.size, 'rtp_ticks' => 0,
      'unordered_packets' => 0, 'timestamp_wraps' => 0 }
  end

  def synthetic_epoch_decode(packets, offsets: nil, capacity: Whatsapp::RecordingWavChunk::CAPACITY, limits: {})
    data = synthetic_capture(packets, offsets: offsets)
    artifact = synthetic_capture_artifact(packets, data: data, offsets: offsets)
    epoch = artifact.slice('side', 'source_kind', 'generation', 'ssrc', 'continuity_reason').merge('id' => 'epoch_000001', 'artifacts' => [artifact])
    Dir.mktmpdir('synthetic-opus-') do |dir|
      budget = Whatsapp::RecordingDecodeBudget.new(limits: limits)
      sink = Whatsapp::RecordingPcmChunks.new(dir: dir, budget: budget, capacity: capacity)
      summary = run_fixture_epoch(epoch, sink, budget, data, artifact)
      pcm = sink.chunks.map { |chunk| File.binread(chunk['path']).byteslice(44..) }.join.b
      { summary: summary, chunks: sink.chunks.map { |chunk| chunk.except('path') }, pcm: pcm }
    ensure
      sink&.close
    end
  end

  def run_fixture_epoch(epoch, sink, budget, data, artifact)
    decoder = Whatsapp::RecordingEpochDecoder.new(epoch: epoch, sink: sink, budget: budget)
    reader = Whatsapp::RecordingCaptureReader.new(io: StringIO.new(data), artifact: artifact, budget: budget)
    decoder.perform { |accept| reader.each { |packet| accept.call(packet) } }
  end
end

RSpec.configure { |config| config.include WhatsappOpusFixtures }
