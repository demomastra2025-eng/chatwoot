require 'zlib'

class Crm::Deals::XlsxBuilder
  FORMULA_PREFIX_REGEX = /\A(?:[\t\r\n]|[\s\u00A0]*[=+\-@])/
  INVALID_XML_CHARS_REGEX = /[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]/
  MAX_CELL_LENGTH = 32_767
  DOS_EPOCH_DATE = 0x0021
  WORKSHEET_CONTENT_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'.freeze
  WORKSHEET_REL_TYPE = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet'.freeze
  STYLES_REL_TYPE = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles'.freeze

  def self.build(sheets)
    new(sheets).build
  end

  def initialize(sheets)
    @sheets = Array(sheets)
  end

  def build
    entries = [
      ['[Content_Types].xml', content_types_xml],
      ['_rels/.rels', root_rels_xml],
      ['xl/workbook.xml', workbook_xml],
      ['xl/_rels/workbook.xml.rels', workbook_rels_xml],
      ['xl/styles.xml', styles_xml]
    ]
    @sheets.each_with_index do |sheet, idx|
      entries << ["xl/worksheets/sheet#{idx + 1}.xml", worksheet_xml(sheet[:rows] || [])]
    end
    pack_zip(entries)
  end

  private

  def content_types_xml
    overrides = @sheets.each_index.map do |idx|
      %(<Override PartName="/xl/worksheets/sheet#{idx + 1}.xml" ContentType="#{WORKSHEET_CONTENT_TYPE}"/>)
    end.join
    <<~XML.squish
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        #{overrides}
      </Types>
    XML
  end

  def root_rels_xml
    <<~XML.squish
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      </Relationships>
    XML
  end

  def workbook_xml
    sheet_nodes = @sheets.each_with_index.map do |sheet, idx|
      safe_name = escape_xml(sanitize_sheet_name(sheet[:name], idx + 1))
      %(<sheet name="#{safe_name}" sheetId="#{idx + 1}" r:id="rId#{idx + 1}"/>)
    end.join
    <<~XML.squish
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>#{sheet_nodes}</sheets>
      </workbook>
    XML
  end

  def workbook_rels_xml
    rels = @sheets.each_index.map do |idx|
      %(<Relationship Id="rId#{idx + 1}" Type="#{WORKSHEET_REL_TYPE}" Target="worksheets/sheet#{idx + 1}.xml"/>)
    end
    rels << %(<Relationship Id="rId#{@sheets.size + 1}" Type="#{STYLES_REL_TYPE}" Target="styles.xml"/>)
    <<~XML.squish
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        #{rels.join}
      </Relationships>
    XML
  end

  def styles_xml
    <<~XML.squish
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF1F5F9"/></patternFill></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="2">
          <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
          <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
        </cellXfs>
      </styleSheet>
    XML
  end

  def worksheet_xml(rows)
    out = String.new(capacity: 4096)
    out << '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    out << '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
    rows.each_with_index do |row, r_idx|
      append_worksheet_row!(out, row, r_idx + 1, r_idx.zero? ? ' s="1"' : '')
    end
    out << '</sheetData></worksheet>'
  end

  def append_worksheet_row!(out, row, row_num, style_attr)
    out << %(<row r="#{row_num}">)
    Array(row).each_with_index do |cell, c_idx|
      out << render_cell(cell, "#{column_letters(c_idx)}#{row_num}", style_attr)
    end
    out << '</row>'
  end

  def render_cell(value, cell_ref, style_attr)
    return %(<c r="#{cell_ref}"#{style_attr}/>) if value.nil? || value == ''

    if numeric_cell?(value)
      %(<c r="#{cell_ref}"#{style_attr} t="n"><v>#{value}</v></c>)
    else
      safe_text = escape_xml(sanitize_cell_string(value))
      %(<c r="#{cell_ref}"#{style_attr} t="inlineStr"><is><t xml:space="preserve">#{safe_text}</t></is></c>)
    end
  end

  def numeric_cell?(value)
    (value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal)) &&
      !(value.respond_to?(:finite?) && !value.finite?)
  end

  def sanitize_cell_string(value)
    str = value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).gsub(INVALID_XML_CHARS_REGEX, '')
    escaped = str.match?(FORMULA_PREFIX_REGEX) ? "'#{str}" : str
    escaped[0, MAX_CELL_LENGTH]
  end

  def sanitize_sheet_name(name, fallback_index)
    cleaned = name.to_s.gsub(%r{[\\/*?:\[\]]}, ' ').strip
    cleaned = "Sheet#{fallback_index}" if cleaned.blank?
    cleaned[0, 31]
  end

  def escape_xml(str)
    str.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;').gsub("'", '&apos;')
  end

  def column_letters(index)
    result = +''
    n = index
    loop do
      result.prepend((65 + (n % 26)).chr)
      n = (n / 26) - 1
      break if n.negative?
    end
    result
  end

  def pack_zip(entries)
    body = String.new(encoding: Encoding::BINARY)
    central_dir = String.new(encoding: Encoding::BINARY)
    entries.each { |filename, raw_content| append_zip_entry!(body, central_dir, filename, raw_content) }
    eocd = [0x06054b50, 0, 0, entries.size, entries.size, central_dir.bytesize, body.bytesize, 0].pack('VvvvvVVv')
    body << central_dir << eocd
  end

  def append_zip_entry!(body, central_dir, filename, raw_content)
    name_bytes = filename.to_s.b
    uncompressed = raw_content.to_s.b
    crc = Zlib.crc32(uncompressed)
    compressed = deflate_raw(uncompressed)
    local_offset = body.bytesize

    body << zip_local_header(crc, compressed.bytesize, uncompressed.bytesize, name_bytes.bytesize) << name_bytes << compressed
    central_dir << zip_central_header(crc, compressed.bytesize, uncompressed.bytesize, name_bytes.bytesize, local_offset) << name_bytes
  end

  def zip_local_header(crc, comp_size, uncomp_size, name_size)
    [0x04034b50, 20, 0, 8, 0, DOS_EPOCH_DATE, crc, comp_size, uncomp_size, name_size, 0].pack('VvvvvvVVVvv')
  end

  def zip_central_header(crc, comp_size, uncomp_size, name_size, local_offset)
    [
      0x02014b50, 20, 20, 0, 8, 0, DOS_EPOCH_DATE, crc, comp_size, uncomp_size,
      name_size, 0, 0, 0, 0, 0, local_offset
    ].pack('VvvvvvvVVVvvvvvVV')
  end

  def deflate_raw(bytes)
    zstream = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
    compressed = zstream.deflate(bytes, Zlib::FINISH)
    zstream.close
    compressed
  end
end
