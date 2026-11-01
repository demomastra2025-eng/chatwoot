# frozen_string_literal: true

require 'zlib'

class Billing::InvoicePdfGenerator
  CANDIDATE_TTF_PATHS = [
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
    '/usr/share/fonts/truetype/montserrat/Montserrat-Regular.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
    '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'
  ].freeze

  UPPER_AGL = (%w[afii10017 afii10018 afii10019 afii10020 afii10021 afii10022] +
               (10_024..10_049).map { |num| "afii#{num}" }).freeze
  LOWER_AGL = (%w[afii10065 afii10066 afii10067 afii10068 afii10069 afii10070] +
               (10_072..10_097).map { |num| "afii#{num}" }).freeze

  class << self
    def cached_ttf_data
      return @cached_ttf_data if defined?(@cached_ttf_data)

      path = CANDIDATE_TTF_PATHS.find { |candidate| File.exist?(candidate) }
      @cached_ttf_data = if path
                           raw = File.binread(path)
                           { length1: raw.bytesize, compressed: Zlib::Deflate.deflate(raw) }
                         end
    end
  end

  def initialize(invoice:)
    @invoice = invoice
    @profile = invoice.account&.billing_account_profile
  end

  def render
    content_stream = build_page_stream
    assemble_pdf(content_stream)
  end

  private

  def build_page_stream
    ops = ['BT', '/F1 14 Tf', '40 800 Td']
    lines = document_lines
    lines.each_with_index do |(text, font_size), idx|
      ops << "/F1 #{font_size} Tf"
      ops << '0 -18 Td' unless idx.zero?
      ops << "(#{encode_pdf_string(text)}) Tj"
    end
    ops << 'ET'
    ops.join("\n")
  end

  def document_lines
    header_lines + party_lines + item_lines + footer_lines
  end

  def header_lines
    issued_str = (@invoice.created_at || Time.current).in_time_zone(Billing::ALMATY_TIMEZONE).strftime('%d.%m.%Y')
    [
      ["СЧЁТ НА ОПЛАТУ № #{@invoice.invoice_number}", 14],
      ["Дата выставления: #{issued_str}   Срок оплаты: #{@invoice.due_on.strftime('%d.%m.%Y')}", 10],
      ['--------------------------------------------------------------------------------', 9]
    ]
  end

  def party_lines
    supplier_bin = Billing::Config.bcc_supplier_bin || 'НЕ УКАЗАН'
    iban = Billing::Config.bcc_business_iban || 'НЕ УКАЗАН'
    [
      ["Поставщик: #{Billing::Config.bcc_supplier_name}, БИН/ИИН: #{supplier_bin}, КБе: #{Billing::Config.bcc_supplier_kbe}", 10],
      ["Банк поставщика: АО «Банк ЦентрКредит», БИК: #{Billing::Config.bcc_supplier_bik}, ИИК: #{iban}", 10],
      buyer_summary_line, contract_summary_line,
      ["Назначение платежа: #{@invoice.payment_purpose}", 10],
      ['--------------------------------------------------------------------------------', 9]
    ]
  end

  def buyer_summary_line
    ["Покупатель: #{@invoice.payer_legal_name || @invoice.account&.name}, БИН/ИИН: #{@invoice.payer_tax_id || 'НЕ УКАЗАН'}", 10]
  end

  def contract_summary_line
    ["Договор: #{@profile&.effective_contract_number || 'Оферта OneLink'}   КНП: #{@invoice.knp_code}", 10]
  end

  def item_lines
    rows = [['Наименование услуги | Кол-во | Сумма (KZT)', 10]]
    Array(@invoice.line_items).each_with_index do |item, idx|
      rows << ["#{idx + 1}. #{item['description']} | #{item['quantity']} | #{format_kzt(item['amount_minor'])} KZT", 9]
    end
    rows
  end

  def footer_lines
    [['--------------------------------------------------------------------------------', 9],
     ["ИТОГО К ОПЛАТЕ (без НДС): #{format_kzt(@invoice.amount_minor)} #{@invoice.currency}", 12]]
  end

  def format_kzt(minor)
    whole, tiyn = minor.to_i.divmod(100)
    grouped = whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse
    format('%<whole>s.%<tiyn>02d', whole: grouped, tiyn: tiyn)
  end

  def encode_pdf_string(str)
    normalized = str.to_s.tr('«»–—₸', '""--T')
    cp1251 = normalized.encode('Windows-1251', invalid: :replace, undef: :replace, replace: '?').b
    escape_pdf_bytes(cp1251)
  end

  def escape_pdf_bytes(bytes)
    out = +''.b
    bytes.each_byte do |byte|
      if [40, 41, 92].include?(byte)
        out << 92 << byte
      elsif byte.between?(32, 126)
        out << byte
      else
        out << format('\\%<oct>03o', oct: byte).b
      end
    end
    out
  end

  def assemble_pdf(content_stream)
    serialize_pdf_objects(build_pdf_objects(content_stream))
  end

  def build_pdf_objects(content_stream)
    ttf = self.class.cached_ttf_data
    objs = [
      '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      font_object_dict(ttf.present?), stream_object(content_stream.b), encoding_object_dict, stream_object(to_unicode_cmap.b)
    ]
    objs.concat(embedded_ttf_objects(ttf)) if ttf.present?
    objs
  end

  def font_object_dict(embed_ttf)
    return '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding 6 0 R /ToUnicode 7 0 R >>' unless embed_ttf

    widths = Array.new(224, 560).join(' ')
    '<< /Type /Font /Subtype /TrueType /BaseFont /OneLinkSans /FirstChar 32 /LastChar 255 ' \
      "/Widths [#{widths}] /FontDescriptor 8 0 R /Encoding 6 0 R /ToUnicode 7 0 R >>"
  end

  def embedded_ttf_objects(ttf)
    descriptor = '<< /Type /FontDescriptor /FontName /OneLinkSans /Flags 32 /FontBBox [-500 -300 1500 1100] ' \
                 '/ItalicAngle 0 /Ascent 900 /Descent -250 /CapHeight 700 /StemV 80 /FontFile2 9 0 R >>'
    font_stream = "<< /Length #{ttf[:compressed].bytesize} /Length1 #{ttf[:length1]} /Filter /FlateDecode >>\n" \
                  "stream\n".b + ttf[:compressed] + "\nendstream".b
    [descriptor, font_stream]
  end

  def encoding_object_dict
    upper = UPPER_AGL.map { |name| "/#{name}" }.join(' ')
    lower = LOWER_AGL.map { |name| "/#{name}" }.join(' ')
    '<< /Type /Encoding /BaseEncoding /WinAnsiEncoding ' \
      "/Differences [168 /afii10023 184 /afii10071 185 /afii61352 192 #{upper} 224 #{lower}] >>"
  end

  def to_unicode_cmap
    mappings = ['<A8> <0401>', '<B8> <0451>', '<B9> <2116>']
    32.times { |idx| mappings << format('<%<src>02X> <%<dst>04X>', src: 0xC0 + idx, dst: 0x0410 + idx) }
    32.times { |idx| mappings << format('<%<src>02X> <%<dst>04X>', src: 0xE0 + idx, dst: 0x0430 + idx) }
    build_cmap_body(mappings)
  end

  def build_cmap_body(mappings)
    "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" \
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" \
      "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" \
      "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" \
      "#{mappings.size} beginbfchar\n#{mappings.join("\n")}\nendbfchar\n" \
      "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend"
  end

  def stream_object(bytes)
    "<< /Length #{bytes.bytesize} >>\nstream\n".b + bytes + "\nendstream".b
  end

  def serialize_pdf_objects(objects)
    buf = +"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
    offsets = []
    objects.each_with_index do |body, index|
      offsets << buf.bytesize
      buf << "#{index + 1} 0 obj\n".b << body.b << "\nendobj\n".b
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
