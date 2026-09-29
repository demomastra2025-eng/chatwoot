require 'digest'

class Whatsapp::RecordingCaptureReader
  MAGIC = "OLRTP1\n".b.freeze
  Packet = Struct.new(:sequence, :timestamp, :ssrc, :payload_type, :payload, :raw_sha256, :offset_ns, keyword_init: true)

  def initialize(io:, artifact:, budget:)
    @io = io
    @artifact = artifact
    @budget = budget
    @digest = Digest::SHA256.new
    @bytes = @packets = 0
    @first_offset = @last_offset = nil
  end

  def each
    return enum_for(:each) unless block_given?

    fail_capture! unless read_exact(MAGIC.bytesize) == MAGIC
    loop do
      header = read_exact(12, eof: true)
      break unless header

      offset, size = header.unpack('Q>L>')
      fail_capture! unless size.between?(13, 65_535)
      packet = parse_packet(read_exact(size), offset)
      @budget.charge!(:packets)
      @packets += 1
      @first_offset = @first_offset ? [@first_offset, offset].min : offset
      @last_offset = @last_offset ? [@last_offset, offset].max : offset
      yield packet
    end
    validate_integrity!
  end

  private

  def read_exact(size, eof: false)
    @budget.check!
    bytes = @io.read(size)
    return if eof && bytes.nil?

    fail_capture! unless bytes && bytes.bytesize == size
    @bytes += size
    fail_capture! if @bytes > @artifact.fetch('byte_size')
    @digest.update(bytes)
    bytes
  end

  def parse_packet(raw, offset)
    fail_capture! unless raw.getbyte(0) >> 6 == 2
    sequence, timestamp, ssrc = raw.byteslice(2, 10).unpack('nNN')
    fail_capture! unless ssrc == @artifact.fetch('ssrc') && offset.between?(@artifact.fetch('first_offset_ns'), @artifact.fetch('last_offset_ns'))

    header_size = rtp_header_size(raw)
    padding = rtp_padding(raw, header_size)

    Packet.new(sequence: sequence, timestamp: timestamp, ssrc: ssrc, payload_type: raw.getbyte(1) & 0x7f,
               payload: raw.byteslice(header_size, raw.bytesize - header_size - padding),
               raw_sha256: Digest::SHA256.hexdigest(raw), offset_ns: offset)
  end

  def rtp_padding(raw, header_size)
    padding = raw.getbyte(0).anybits?(0x20) ? raw.getbyte(-1) : 0
    fail_capture! if raw.getbyte(0).anybits?(0x20) && padding.zero?
    fail_capture! unless raw.bytesize > header_size + padding
    padding
  end

  def rtp_header_size(raw)
    size = 12 + ((raw.getbyte(0) & 0x0f) * 4)
    fail_capture! if size > raw.bytesize
    return size if raw.getbyte(0).nobits?(0x10)

    fail_capture! if size + 4 > raw.bytesize
    size + 4 + (raw.byteslice(size + 2, 2).unpack1('n') * 4)
  end

  def validate_integrity!
    valid = @bytes == @artifact.fetch('byte_size') && @digest.hexdigest == @artifact.fetch('sha256') &&
            @packets == @artifact.fetch('packets') && @artifact.values_at('first_offset_ns', 'last_offset_ns') == [@first_offset, @last_offset]
    fail_capture! unless valid
  end

  def fail_capture!
    raise Whatsapp::RecordingDecodeError, 'invalid_capture'
  end
end
