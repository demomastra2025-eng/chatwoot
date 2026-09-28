class Whatsapp::RecordingCaptureValidator
  class Invalid < StandardError; end

  CAPTURE_MAGIC = "OLRTP1\n".b.freeze

  def initialize(data:, artifact:)
    @data = data
    @artifact = artifact
  end

  def validate!
    raise Invalid, 'Invalid capture magic' unless @data.start_with?(CAPTURE_MAGIC)

    offsets = capture_frame_offsets
    valid_frames = offsets.size == @artifact['packets'] && offsets.minmax == @artifact.values_at('first_offset_ns', 'last_offset_ns')
    raise Invalid, 'Capture packet count mismatch' unless valid_frames
  end

  private

  def capture_frame_offsets
    position = CAPTURE_MAGIC.bytesize
    offsets = []
    while position < @data.bytesize
      raise Invalid, 'Partial capture frame' if @data.bytesize - position < 12

      offset, size = @data.byteslice(position, 12).unpack('Q>L>')
      position += 12
      raise Invalid, 'Invalid capture frame size' unless size.between?(12, 65_535) && position + size <= @data.bytesize

      validate_capture_packet(@data.byteslice(position, size))
      offsets << offset
      position += size
    end
    offsets
  end

  def validate_capture_packet(packet)
    valid_packet = packet.getbyte(0) >> 6 == 2 && packet.byteslice(8, 4).unpack1('L>') == @artifact['ssrc']
    raise Invalid, 'Invalid capture RTP packet' unless valid_packet

    header_size = capture_header_size(packet)
    padded = packet.getbyte(0).anybits?(0x20)
    padding_size = padded ? packet.getbyte(-1) : 0
    raise Invalid, 'Invalid capture RTP padding' if padded && padding_size.zero?
    raise Invalid, 'Empty or truncated capture RTP payload' unless packet.bytesize > header_size + padding_size
  end

  def capture_header_size(packet)
    size = 12 + ((packet.getbyte(0) & 0x0f) * 4)
    raise Invalid, 'Truncated capture RTP header' if size > packet.bytesize
    return size if packet.getbyte(0).nobits?(0x10)

    raise Invalid, 'Truncated capture RTP extension' if size + 4 > packet.bytesize

    size + 4 + (packet.byteslice(size + 2, 2).unpack1('n') * 4)
  end
end
