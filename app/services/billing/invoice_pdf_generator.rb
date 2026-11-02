# frozen_string_literal: true

# The snapshot source adapter stays beside the unchanged renderer and layout.
class Billing::InvoicePdfGenerator # rubocop:disable Metrics/ClassLength
  PAGE_WIDTH_PT = 595
  PAGE_HEIGHT_PT = 842
  MARGIN_X_PT = 40
  USABLE_WIDTH_PT = PAGE_WIDTH_PT - (MARGIN_X_PT * 2)
  TOP_Y_PT = 800
  BOTTOM_Y_PT = 50
  ASCII_FALLBACK_MAP = {
    '«' => '"', '»' => '"', '–' => '-', '—' => '-', '₸' => 'KZT', '№' => 'No.'
  }.freeze

  def initialize(invoice:, font: Billing::TtfFontParser.default_font)
    @invoice = invoice
    @profile = invoice.account&.billing_account_profile
    state = Billing::CompletionState.new(invoice)
    @document = state.context['document'].to_h if state.managed?
    @font = font
    @used_glyphs = {}
  end

  def render
    @used_glyphs = {}
    pages = paginate_wrapped_lines(build_wrapped_lines)
    page_streams = pages.map { |page_lines| build_page_stream(page_lines) }
    serialize_pdf_objects(build_pdf_objects(page_streams))
  end

  private

  def build_wrapped_lines
    document_lines.flat_map do |(text, font_size)|
      wrapped = @font ? @font.wrap_line(text, font_size, max_width_pt: USABLE_WIDTH_PT) : wrap_ascii_fallback(text, font_size)
      wrapped.map { |segment| [segment, font_size] }
    end
  end

  def paginate_wrapped_lines(lines)
    pages = []
    cur = []
    y = TOP_Y_PT
    lines.each do |(text, size)|
      step = [(size * 1.45).round, 14].max
      if cur.any? && (y - step) < BOTTOM_Y_PT
        pages << cur
        cur = []
        y = TOP_Y_PT
      end
      y -= step if cur.any?
      cur << [text, size, step]
    end
    pages << cur if cur.any? || pages.empty?
    pages
  end

  def build_page_stream(page_lines)
    ops = ['BT', '/F1 14 Tf', "#{MARGIN_X_PT} #{TOP_Y_PT} Td"]
    page_lines.each_with_index do |(text, font_size, step), idx|
      ops << "/F1 #{font_size} Tf"
      ops << "0 -#{step} Td" unless idx.zero?
      ops << (@font ? "<#{encode_cid_hex(text)}> Tj" : "(#{encode_ascii_fallback(text)}) Tj")
    end
    (ops << 'ET').join("\n")
  end

  def encode_cid_hex(text)
    text.to_s.each_codepoint.with_object(+'') do |cp, hex|
      gid, mapped = @font.glyph_for_codepoint(cp)
      @used_glyphs[gid] ||= mapped ? cp : 0x003F
      hex << format('%<gid>04X', gid: gid)
    end
  end

  def encode_ascii_fallback(str)
    ascii = str.to_s.gsub(/[«»–—₸№]/, ASCII_FALLBACK_MAP).encode('US-ASCII', invalid: :replace, undef: :replace, replace: '?')
    ascii.gsub(/([()\\])/, '\\\\\1')
  end

  def wrap_ascii_fallback(text, font_size)
    max_chars = [(USABLE_WIDTH_PT / (font_size * 0.55)).floor, 30].max
    text.to_s.scan(/.{1,#{max_chars}}/).presence || ['']
  end

  def document_lines
    header_lines + supplier_party_lines + buyer_party_lines + item_lines + footer_lines
  end

  def header_lines
    issued_str = (@invoice.created_at || Time.current).in_time_zone(Billing::ALMATY_TIMEZONE).strftime('%d.%m.%Y')
    [["СЧЁТ НА ОПЛАТУ № #{@invoice.invoice_number}", 14],
     ["Дата выставления: #{issued_str}   Срок оплаты: #{@invoice.due_on.strftime('%d.%m.%Y')}", 10],
     ['--------------------------------------------------------------------------------', 9]]
  end

  def supplier_party_lines
    supplier_bin = document_value('supplier_bin') || 'НЕ УКАЗАН'
    iban = document_value('supplier_iban') || 'НЕ УКАЗАН'
    [["Поставщик: #{document_value('supplier_name')}, БИН/ИИН: #{supplier_bin}, КБе: #{document_value('supplier_kbe')}", 10],
     ["Банк поставщика: АО «Банк ЦентрКредит», БИК: #{document_value('supplier_bik')}, ИИК: #{iban}", 10]]
  end

  def buyer_party_lines
    buyer_name = @invoice.payer_legal_name || @invoice.account&.name
    contract_str = @document ? @document['contract_number'] : (@profile&.effective_contract_number || 'Оферта OneLink')
    [["Покупатель: #{buyer_name}, БИН/ИИН: #{@invoice.payer_tax_id || 'НЕ УКАЗАН'}", 10],
     ["Договор: #{contract_str}   КНП: #{@invoice.knp_code}", 10],
     ["Назначение платежа: #{@invoice.payment_purpose}", 10],
     ['--------------------------------------------------------------------------------', 9]]
  end

  def document_value(key)
    return @document[key] if @document

    field = { 'supplier_name' => :bcc_supplier_name, 'supplier_bin' => :bcc_supplier_bin,
              'supplier_iban' => :bcc_business_iban, 'supplier_bik' => :bcc_supplier_bik, 'supplier_kbe' => :bcc_supplier_kbe }.fetch(key)
    Billing::Config.public_send(field)
  end

  def item_lines
    rows = Array(@invoice.line_items).each_with_index.map do |item, idx|
      ["#{idx + 1}. #{item['description']} | #{item['quantity']} | #{format_kzt(item['amount_minor'])} KZT (₸)", 9]
    end
    [['Наименование услуги | Кол-во | Сумма (KZT / ₸)', 10]] + rows
  end

  def footer_lines
    [['--------------------------------------------------------------------------------', 9],
     ["ИТОГО К ОПЛАТЕ (без НДС): #{format_kzt(@invoice.amount_minor)} #{@invoice.currency} (₸)", 12]]
  end

  def format_kzt(minor)
    whole, tiyn = minor.to_i.divmod(100)
    grouped = whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse
    format('%<whole>s.%<tiyn>02d', whole: grouped, tiyn: tiyn)
  end

  def build_pdf_objects(page_streams)
    page_count = page_streams.size
    font_obj_num = 3 + (page_count * 2)
    kids_refs = Array.new(page_count) { |idx| "#{3 + (idx * 2)} 0 R" }.join(' ')
    objs = ['<< /Type /Catalog /Pages 2 0 R >>', "<< /Type /Pages /Kids [#{kids_refs}] /Count #{page_count} >>"]
    page_streams.each_with_index do |stream, idx|
      objs << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{PAGE_WIDTH_PT} #{PAGE_HEIGHT_PT}] " \
              "/Resources << /Font << /F1 #{font_obj_num} 0 R >> >> /Contents #{4 + (idx * 2)} 0 R >>"
      objs << stream_object(stream.b)
    end
    objs.concat(@font ? composite_font_objects(font_obj_num) : ['<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'])
  end

  def composite_font_objects(base)
    [
      '<< /Type /Font /Subtype /Type0 /BaseFont /OneLinkDejaVuSans /Encoding /Identity-H ' \
      "/DescendantFonts [#{base + 1} 0 R] /ToUnicode #{base + 4} 0 R >>",
      cid_font_dict(base + 2),
      font_descriptor_dict(base + 3),
      ttf_stream_object,
      stream_object(to_unicode_cmap.b)
    ]
  end

  def cid_font_dict(desc_num)
    widths_entries = @used_glyphs.keys.sort.map { |gid| "#{gid} [#{@font.glyph_width(gid)}]" }.join(' ')
    '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /OneLinkDejaVuSans ' \
      '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> ' \
      "/FontDescriptor #{desc_num} 0 R /DW 600 /W [#{widths_entries}] /CIDToGIDMap /Identity >>"
  end

  def font_descriptor_dict(file_num)
    bbox_str = @font.bbox.join(' ')
    "<< /Type /FontDescriptor /FontName /OneLinkDejaVuSans /Flags 32 /FontBBox [#{bbox_str}] " \
      "/ItalicAngle 0 /Ascent #{@font.ascent} /Descent #{@font.descent} /CapHeight 729 /StemV 80 /FontFile2 #{file_num} 0 R >>"
  end

  def ttf_stream_object
    comp = @font.compressed_bytes
    "<< /Length #{comp.bytesize} /Length1 #{@font.raw_bytes.bytesize} /Filter /FlateDecode >>\nstream\n".b + comp + "\nendstream".b
  end

  def to_unicode_cmap
    pairs = @used_glyphs.sort_by(&:first).map { |gid, cp| format('<%<gid>04X> <%<cp>04X>', gid: gid, cp: cp) }
    blocks = pairs.each_slice(100).map { |chunk| "#{chunk.size} beginbfchar\n#{chunk.join("\n")}\nendbfchar" }.join("\n")
    "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" \
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" \
      "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" \
      "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n" \
      "#{blocks}\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend"
  end

  def stream_object(bytes)
    "<< /Length #{bytes.bytesize} >>\nstream\n".b + bytes + "\nendstream".b
  end

  def serialize_pdf_objects(objects)
    buf = +"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
    offsets = objects.each_with_index.map do |body, index|
      buf.bytesize.tap { buf << "#{index + 1} 0 obj\n".b << body.b << "\nendobj\n".b }
    end
    append_xref_and_trailer(buf, offsets)
    buf
  end

  def append_xref_and_trailer(buf, offsets)
    xref_pos = buf.bytesize
    buf << "xref\n0 #{offsets.size + 1}\n0000000000 65535 f \n".b
    offsets.each { |off| buf << format("%<off>010d 00000 n \n", off: off).b }
    buf << "trailer\n<< /Size #{offsets.size + 1} /Root 1 0 R >>\nstartxref\n#{xref_pos}\n%%EOF\n".b
  end
end
