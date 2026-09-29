require 'fiddle'

# Loading this class does not load libopus. Every native call uses owned,
# bounded buffers; one mutex serializes decode/close for each decoder state.
class Whatsapp::NativeOpusDecoder
  class Unavailable < StandardError; end
  class InvalidPacket < StandardError; end

  RATE = 48_000
  CHANNELS = 2
  MAX_SAMPLES = 5760
  MAX_PACKET_BYTES = 65_535
  Frame = Struct.new(:pcm, :samples, :packet_channels, keyword_init: true)

  Library = Whatsapp::NativeOpusLibrary

  attr_reader :version

  def initialize(library: nil)
    @library = library || Library.new
    @version = @library.version
    @mutex = Mutex.new
    allocate_buffers
    create_decoder
  rescue StandardError, NoMemoryError
    close
    raise
  end

  def decode(payload)
    @mutex.synchronize do
      ensure_open!
      copy_payload(payload)
      expected, packet_channels = packet_information(payload.bytesize)
      actual = @library.call(:decode, @decoder, @input, payload.bytesize, @pcm, MAX_SAMPLES, 0)
      raise InvalidPacket, 'opus_decode_failed' unless actual == expected

      Frame.new(pcm: pcm_bytes(actual), samples: actual, packet_channels: packet_channels)
    end
  end

  def conceal(samples)
    valid = samples.is_a?(Integer) && samples.between?(120, MAX_SAMPLES) && (samples % 120).zero?
    raise InvalidPacket, 'invalid_concealment_size' unless valid

    @mutex.synchronize do
      ensure_open!
      actual = @library.call(:decode, @decoder, 0, 0, @pcm, samples, 0)
      raise InvalidPacket, 'opus_concealment_failed' unless actual == samples

      actual
    end
  end

  def close
    return unless @mutex

    @mutex.synchronize do
      if @decoder && !@decoder.null?
        @library.call(:destroy, @decoder)
        @decoder = nil
      end
      [@input, @pcm].compact.each { |pointer| pointer.call_free unless pointer.freed? }
      @input = @pcm = nil
    end
  end

  private

  def allocate_buffers
    @input = Fiddle::Pointer.malloc(MAX_PACKET_BYTES, Fiddle::RUBY_FREE)
    @pcm = Fiddle::Pointer.malloc(MAX_SAMPLES * CHANNELS * 2, Fiddle::RUBY_FREE)
  end

  def create_decoder
    error = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT, Fiddle::RUBY_FREE)
    error[0, Fiddle::SIZEOF_INT] = [0].pack('i!')
    @decoder = @library.call(:create, RATE, CHANNELS, error)
    raise Unavailable, 'opus_decoder_allocation_failed' if @decoder.null? || error[0, Fiddle::SIZEOF_INT].unpack1('i!') != 0
  ensure
    error&.call_free
  end

  def copy_payload(payload)
    valid = payload.is_a?(String) && payload.bytesize.between?(1, MAX_PACKET_BYTES)
    raise InvalidPacket, 'invalid_opus_payload_size' unless valid

    @input[0, payload.bytesize] = payload
  end

  def packet_information(size)
    samples = @library.call(:samples, @input, size, RATE)
    frames = @library.call(:frames, @input, size)
    channels = @library.call(:channels, @input)
    valid = samples.between?(120, MAX_SAMPLES) && (samples % 120).zero? && frames.between?(1, 48) && [1, 2].include?(channels)
    raise InvalidPacket, 'invalid_opus_packet' unless valid

    [samples, channels]
  end

  def ensure_open!
    raise InvalidPacket, 'opus_decoder_closed' unless @decoder
  end

  def pcm_bytes(samples)
    bytes = @pcm[0, samples * CHANNELS * 2]
    [1].pack('S') == "\x01\x00".b ? bytes : bytes.unpack('s!*').pack('s<*')
  end
end
