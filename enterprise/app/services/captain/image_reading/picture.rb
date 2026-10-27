# frozen_string_literal: true

require 'base64'
require 'stringio'
require 'vips'

# The bytes of a customer's image and the two forms in which models see it. A model always receives the image as data inside the
# request, never as a link: a provider that fetches a link does it at every request, and a link to a customer's file is no business
# of a provider (owner 27.10).
#
# for_reader: the image as it is when its long side is at most READER_LONG_SIDE, its type is one that providers take and it carries no
# metadata (EXIF, XMP, IPTC: the place and the time of a photo are no business of a provider, and an EXIF orientation is a turn that a
# provider may not apply); else a JPEG of that long side, turned upright and without metadata. A smaller image costs fewer tokens and
# reads as well (benchmark 27.10, 80 images).
# for_router: always a JPEG whose long side is at most ROUTER_LONG_SIDE; the router only has to tell whether there is handwriting.
# libvips (the library of the product's image processing) does the resizing: about 0.05-0.2 s, header-only for the size check.
class Captain::ImageReading::Picture
  READER_LONG_SIDE = 1536
  ROUTER_LONG_SIDE = 1024
  READER_JPEG_QUALITY = 85
  ROUTER_JPEG_QUALITY = 80
  SENDABLE_TYPES = %w[image/jpeg image/png image/webp].freeze
  EXTENSIONS = { 'image/jpeg' => 'jpg', 'image/png' => 'png', 'image/webp' => 'webp' }.freeze
  # An original larger than this is not read (the largest file a provider takes is about 20 MB).
  MAX_ORIGINAL_BYTES = 25 * 1024 * 1024
  # An image with more pixels is not decoded: a small file can hold billions of pixels (a decompression bomb) and would tie up a
  # thread of a run or a worker. The size is read from the header, so the check costs nothing. The photo of an ordinary phone camera
  # (12 to 48 MP) is far below it; a file above MAX_ORIGINAL_BYTES is refused before that.
  MAX_PIXELS = 100_000_000
  # The fields of libvips that hold the metadata of a file, and the one that holds its turn (1 = upright).
  METADATA_FIELDS = %w[exif-data xmp-data iptc-data].freeze
  ORIENTATION_FIELD = 'orientation'

  # The file or the type of the image cannot be used, or it could not be fetched. The message names no URL and no content.
  class Unreadable < StandardError; end

  Form = Struct.new(:bytes, :content_type, keyword_init: true) do
    def filename = "image.#{EXTENSIONS.fetch(content_type)}"

    def data_url = "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"

    def io = StringIO.new(bytes)
  end

  class << self
    # The image of an attachment: its file in the storage, else the URL the caller knows (the external link of a channel). Nothing
    # here downloads an image to learn its type: the type is read from the bytes that are needed anyway.
    def load(attachment:, url:)
      file = attachment&.file
      return from_blob(file.blob) if file&.attached?

      fetch(url)
    end

    private

    def from_blob(blob)
      raise Unreadable, 'the image is too large' if blob.byte_size.to_i > MAX_ORIGINAL_BYTES

      new(bytes: blob.download, content_type: blob.content_type)
    end

    def fetch(url)
      raise Unreadable, 'the image has no source' if url.blank?

      SafeFetch.fetch(url, max_bytes: MAX_ORIGINAL_BYTES, allowed_content_type_prefixes: %w[image/]) do |result|
        new(bytes: result.tempfile.read, content_type: result.content_type)
      end
    rescue SafeFetch::Error => e
      raise Unreadable, "the image could not be fetched (#{e.class.name.demodulize})"
    end
  end

  attr_reader :bytes, :content_type

  # content_type: the type the storage or the channel declares; the bytes decide (Marcel reads their first bytes).
  def initialize(bytes:, content_type: nil)
    @bytes = bytes.to_s.b
    raise Unreadable, 'the image is empty' if @bytes.empty?

    @content_type = Marcel::MimeType.for(StringIO.new(@bytes), declared_type: content_type)
    raise Unreadable, 'the file is not an image' unless @content_type.start_with?('image/')
  end

  def long_side
    @long_side ||= begin
      width, height = dimensions
      raise Unreadable, 'the image is too large' if width * height > MAX_PIXELS

      [width, height].max
    end
  end

  def for_reader
    @for_reader ||= if as_is?
                      Form.new(bytes: bytes, content_type: content_type)
                    else
                      jpeg(READER_LONG_SIDE, READER_JPEG_QUALITY)
                    end
  end

  def for_router
    @for_router ||= jpeg(ROUTER_LONG_SIDE, ROUTER_JPEG_QUALITY)
  end

  private

  # The header of the image, read without decoding its pixels.
  def header
    @header ||= Vips::Image.new_from_buffer(@bytes, '')
  rescue Vips::Error
    raise Unreadable, 'the image cannot be decoded'
  end

  def dimensions
    [header.width, header.height]
  end

  # Whether the stored file goes out unchanged: small enough, of a type providers take, upright and without metadata.
  def as_is?
    long_side <= READER_LONG_SIDE && SENDABLE_TYPES.include?(content_type) && !metadata? && upright?
  end

  def metadata?
    header.get_fields.intersect?(METADATA_FIELDS)
  end

  def upright?
    header.get_fields.exclude?(ORIENTATION_FIELD) || header.get(ORIENTATION_FIELD) == 1
  end

  # `size: :down` never enlarges a small image; thumbnail turns the image the way its EXIF orientation says.
  def jpeg(side, quality)
    long_side # refuses an image with too many pixels before anything decodes it
    image = Vips::Image.thumbnail_buffer(bytes, side, height: side, size: :down)
    image = image.flatten(background: [255, 255, 255]) if image.has_alpha?
    Form.new(bytes: image.write_to_buffer('.jpg', Q: quality, strip: true), content_type: 'image/jpeg')
  rescue Vips::Error
    raise Unreadable, 'the image cannot be decoded'
  end
end
