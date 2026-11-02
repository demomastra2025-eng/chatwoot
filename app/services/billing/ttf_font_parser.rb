# frozen_string_literal: true

require 'zlib'

class Billing::TtfFontParser
  DEFAULT_TTF_PATH = File.expand_path('../../../lib/fonts/billing/DejaVuSans.ttf', __dir__).freeze
  DEFAULT_GLYPH_WIDTH = 600

  attr_reader :raw_bytes, :compressed_bytes, :units_per_em, :bbox, :ascent, :descent, :widths, :cmap

  class << self
    def default_font
      @default_font ||= new(File.binread(DEFAULT_TTF_PATH))
    end
  end

  def initialize(raw_bytes)
    @raw_bytes = raw_bytes.b
    @compressed_bytes = Zlib::Deflate.deflate(@raw_bytes)
    tables = parse_table_directory
    parse_head_and_hhea(tables)
    parse_glyph_widths(tables)
    @cmap = parse_unicode_cmap(tables['cmap'])
  end

  def glyph_for_codepoint(codepoint)
    return [@cmap[codepoint], true] if @cmap.key?(codepoint)

    fallback_gid = @cmap[0x3F] || 0
    [fallback_gid, false]
  end

  def glyph_width(gid)
    @widths[gid] || DEFAULT_GLYPH_WIDTH
  end

  def measure_pt(text, font_size)
    total_units = text.to_s.each_codepoint.sum do |cp|
      gid, = glyph_for_codepoint(cp)
      glyph_width(gid)
    end
    (total_units * font_size) / 1000.0
  end

  def wrap_line(text, font_size, max_width_pt: 515.0)
    str = text.to_s
    return [''] if str.empty?
    return [str] if measure_pt(str, font_size) <= max_width_pt

    wrap_tokens(str.scan(/\S+|\s+/), font_size, max_width_pt)
  end

  private

  def wrap_tokens(tokens, font_size, max_width_pt)
    lines = []
    current = +''
    tokens.each do |tok|
      next if current.empty? && tok.match?(/\A\s+\z/)

      if measure_pt(current + tok, font_size) <= max_width_pt
        current << tok
      else
        flush_or_split_token(lines, current, tok, font_size, max_width_pt).tap { |rem| current = rem }
      end
    end
    lines << current.rstrip unless current.empty?
    lines.presence || ['']
  end

  def flush_or_split_token(lines, current, tok, font_size, max_width_pt)
    lines << current.rstrip unless current.empty?
    stripped = tok.lstrip
    return +'' if stripped.empty?
    return +stripped if measure_pt(stripped, font_size) <= max_width_pt

    split_oversized_token(lines, stripped, font_size, max_width_pt)
  end

  def split_oversized_token(lines, token, font_size, max_width_pt)
    chunk = +''
    token.each_char do |ch|
      if !chunk.empty? && measure_pt(chunk + ch, font_size) > max_width_pt
        lines << chunk
        chunk = +ch
      else
        chunk << ch
      end
    end
    chunk
  end

  def parse_table_directory
    num_tables = @raw_bytes.byteslice(4, 2).unpack1('n')
    (0...num_tables).each_with_object({}) do |idx, dir|
      pos = 12 + (idx * 16)
      tag = @raw_bytes.byteslice(pos, 4)
      _csum, offset, length = @raw_bytes.byteslice(pos + 4, 12).unpack('NNN')
      dir[tag] = { offset: offset, length: length }
    end
  end

  def parse_head_and_hhea(tables)
    head_off = tables.fetch('head')[:offset]
    hhea_off = tables.fetch('hhea')[:offset]
    @units_per_em = @raw_bytes.byteslice(head_off + 18, 2).unpack1('n')
    raw_bbox = @raw_bytes.byteslice(head_off + 36, 8).unpack('s>4')
    @bbox = raw_bbox.map { |val| scale_em(val) }
    raw_asc, raw_desc = @raw_bytes.byteslice(hhea_off + 4, 4).unpack('s>2')
    @ascent = scale_em(raw_asc)
    @descent = scale_em(raw_desc)
    @num_h_metrics = @raw_bytes.byteslice(hhea_off + 34, 2).unpack1('n')
  end

  def parse_glyph_widths(tables)
    num_glyphs = @raw_bytes.byteslice(tables.fetch('maxp')[:offset] + 4, 2).unpack1('n')
    hmtx_off = tables.fetch('hmtx')[:offset]
    scaled = Array.new(@num_h_metrics) do |gid|
      scale_em(@raw_bytes.byteslice(hmtx_off + (gid * 4), 2).unpack1('n'))
    end
    last_w = scaled.last || DEFAULT_GLYPH_WIDTH
    scaled.fill(last_w, @num_h_metrics...num_glyphs) if num_glyphs > @num_h_metrics
    @widths = scaled
  end

  def scale_em(value)
    ((value * 1000.0) / @units_per_em).round
  end

  def parse_unicode_cmap(cmap_entry)
    return {} unless cmap_entry

    subtables = read_cmap_subtables(cmap_entry[:offset])
    fmt12 = find_unicode_subtable(subtables, 12)
    return parse_cmap_format12(fmt12[:offset]) if fmt12

    fmt4 = find_unicode_subtable(subtables, 4)
    fmt4 ? parse_cmap_format4(fmt4[:offset]) : {}
  end

  def find_unicode_subtable(subtables, fmt)
    subtables.find { |sub| sub[:format] == fmt && unicode_platform?(sub) }
  end

  def read_cmap_subtables(base)
    count = @raw_bytes.byteslice(base + 2, 2).unpack1('n')
    Array.new(count) do |idx|
      plat, enc, rel = @raw_bytes.byteslice(base + 4 + (idx * 8), 8).unpack('nnN')
      off = base + rel
      { platform: plat, encoding: enc, offset: off, format: @raw_bytes.byteslice(off, 2).unpack1('n') }
    end
  end

  def unicode_platform?(sub)
    sub[:platform].zero? || (sub[:platform] == 3 && [1, 10].include?(sub[:encoding]))
  end

  def parse_cmap_format12(off)
    num_groups = @raw_bytes.byteslice(off + 12, 4).unpack1('N')
    (0...num_groups).each_with_object({}) do |idx, map|
      start_cp, end_cp, start_gid = @raw_bytes.byteslice(off + 16 + (idx * 12), 12).unpack('NNN')
      next if start_cp > 0xFFFF

      (start_cp..[end_cp, 0xFFFF].min).each { |cp| map[cp] = start_gid + (cp - start_cp) }
    end
  end

  def parse_cmap_format4(off)
    seg_x2 = @raw_bytes.byteslice(off + 6, 2).unpack1('n')
    range_off_pos = off + 16 + (seg_x2 * 3)
    decode_format4_segments(
      seg_count: seg_x2 / 2,
      end_codes: @raw_bytes.byteslice(off + 14, seg_x2).unpack('n*'),
      start_codes: @raw_bytes.byteslice(off + 16 + seg_x2, seg_x2).unpack('n*'),
      id_deltas: @raw_bytes.byteslice(off + 16 + (seg_x2 * 2), seg_x2).unpack('s>*'),
      range_offsets: @raw_bytes.byteslice(range_off_pos, seg_x2).unpack('n*'),
      range_off_pos: range_off_pos
    )
  end

  def decode_format4_segments(seg_data)
    (0...seg_data[:seg_count]).each_with_object({}) do |idx, map|
      sc = seg_data[:start_codes][idx]
      next if sc == 0xFFFF

      (sc..seg_data[:end_codes][idx]).each do |cp|
        gid = format4_gid(cp, sc, seg_data[:id_deltas][idx], seg_data[:range_offsets][idx], seg_data[:range_off_pos] + (idx * 2))
        map[cp] = gid if gid.positive?
      end
    end
  end

  def format4_gid(codepoint, start_code, delta, range_offset, range_slot_pos)
    return (codepoint + delta) & 0xFFFF if range_offset.zero?

    glyph_pos = range_slot_pos + range_offset + ((codepoint - start_code) * 2)
    raw_gid = @raw_bytes.byteslice(glyph_pos, 2).unpack1('n')
    raw_gid.zero? ? 0 : (raw_gid + delta) & 0xFFFF
  end
end
