module WhatsappWeb::MediaBinaryCodec
  KEY_LENGTH = 32

  module_function

  def decode_binary_field(value, field_name: 'binary_field')
    return nil if value.blank?
    return decode_string_field(value, field_name) if value.is_a?(String)
    return pack_byte_array(value, field_name) if value.is_a?(Array)
    return decode_hash_field(value, field_name) if value.is_a?(Hash)

    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Unsupported #{field_name} format: #{value.class}"
  end

  def parse_file_length(value)
    return (value >= 0 ? value : nil) if value.is_a?(Integer)
    return parse_numeric_string(value) if value.is_a?(String)
    return parse_long_hash(value) if value.is_a?(Hash)

    nil
  end

  def parse_numeric_string(value)
    stripped = value.strip
    stripped.match?(/\A\d+\z/) ? stripped.to_i : nil
  end

  def decode_string_field(value, field_name)
    trimmed = value.strip
    if value.encoding == Encoding::ASCII_8BIT && value.bytesize == KEY_LENGTH && !trimmed.match?(%r{\A[A-Za-z0-9+/_=-]{42,48}\z})
      return value.dup.force_encoding(Encoding::BINARY)
    end

    b64 = trimmed.tr('-_', '+/').delete("\r\n ")
    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Invalid Base64 #{field_name}" unless b64.match?(%r{\A[A-Za-z0-9+/]+={0,2}\z})

    raw_b64 = b64.delete('=')
    rem = raw_b64.length % 4
    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Invalid Base64 length for #{field_name}" if rem == 1

    padded = raw_b64 + ('=' * ((4 - rem) % 4))
    Base64.strict_decode64(padded).force_encoding(Encoding::BINARY)
  rescue ArgumentError => e
    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Invalid Base64 #{field_name}: #{e.message}"
  end

  def decode_hash_field(value, field_name)
    buffer_data = extract_buffer_data(value)
    return pack_byte_array(buffer_data, field_name) if buffer_data

    indexed = value.transform_keys { |key| parse_byte_index(key, field_name) }
    bytes = (0...indexed.size).map do |idx|
      raise WhatsappWeb::MediaDecryptor::DecryptionError, "Missing index #{idx} in #{field_name}" unless indexed.key?(idx)

      indexed[idx]
    end
    pack_byte_array(bytes, field_name)
  end

  def extract_buffer_data(value)
    type = value[:type] || value['type']
    data = value[:data] || value['data']
    data if type.to_s == 'Buffer' && data.is_a?(Array)
  end

  def parse_byte_index(key, field_name)
    return key if key.is_a?(Integer) && key >= 0

    str = key.to_s
    return str.to_i if str.match?(/\A\d+\z/)

    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Invalid key #{key.inspect} in #{field_name}"
  end

  def pack_byte_array(array, field_name)
    bytes = array.map do |item|
      unless item.is_a?(Integer) && item.between?(0, 255)
        raise WhatsappWeb::MediaDecryptor::DecryptionError, "Invalid byte #{item.inspect} in #{field_name}"
      end

      item
    end
    bytes.pack('C*').force_encoding(Encoding::BINARY)
  end

  def parse_long_hash(hash)
    return nil unless hash.key?(:low) || hash.key?('low')

    low = (hash[:low] || hash['low']).to_i & 0xffffffff
    high = (hash[:high] || hash['high']).to_i & 0xffffffff
    (high << 32) | low
  end
end
