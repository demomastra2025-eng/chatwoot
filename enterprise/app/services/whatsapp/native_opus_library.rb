require 'fiddle'

class Whatsapp::NativeOpusLibrary
  POINTER = Fiddle::TYPE_VOIDP
  INTEGER = Fiddle::TYPE_INT
  SIGNATURES = {
    create: ['opus_decoder_create', [INTEGER, INTEGER, POINTER], POINTER],
    destroy: ['opus_decoder_destroy', [POINTER], Fiddle::TYPE_VOID],
    decode: ['opus_decode', [POINTER, POINTER, INTEGER, POINTER, INTEGER, INTEGER], INTEGER],
    samples: ['opus_packet_get_nb_samples', [POINTER, INTEGER, INTEGER], INTEGER],
    frames: ['opus_packet_get_nb_frames', [POINTER, INTEGER], INTEGER],
    channels: ['opus_packet_get_nb_channels', [POINTER], INTEGER],
    version: ['opus_get_version_string', [], POINTER]
  }.freeze

  def initialize(paths: ['libopus.so.0', 'libopus.dylib', 'opus.dll'])
    @handle = load_library(paths)
    @functions = SIGNATURES.transform_values { |name, arguments, result| Fiddle::Function.new(@handle[name], arguments, result) }
  rescue Fiddle::DLError
    raise Whatsapp::NativeOpusDecoder::Unavailable, 'opus_library_unavailable'
  end

  def call(name, *)
    @functions.fetch(name).call(*)
  end

  def version
    call(:version).to_s
  end

  private

  def load_library(paths)
    paths.each do |path|
      return Fiddle.dlopen(path)
    rescue Fiddle::DLError
      next
    end
    raise Whatsapp::NativeOpusDecoder::Unavailable, 'opus_library_unavailable'
  end
end
