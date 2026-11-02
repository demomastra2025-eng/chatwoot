class Messages::HistoryMediaProjection
  PUBLIC_FIELDS = {
    'history_attachment' => %w[unavailable deferred kind file_name mimetype fetch_state],
    'telegram_unavailable_attachments' => %w[kind filename content_type fetch_state]
  }.freeze

  def self.call(value)
    attributes = value.is_a?(String) ? JSON.parse(value) : value
    return attributes unless attributes.is_a?(Hash)

    attributes.deep_dup.each_with_object({}) do |(key, entry), result|
      fields = PUBLIC_FIELDS[key.to_s]
      result[key] = fields ? project_entry(entry, fields) : entry
    end
  rescue JSON::ParserError
    {}
  end

  def self.project_entry(entry, fields)
    case entry
    when Hash
      entry.select { |field, value| fields.include?(field.to_s) && scalar?(value) }
    when Array
      entry.grep(Hash).map { |item| project_entry(item, fields) }
    end
  end

  def self.scalar?(value)
    !value.is_a?(Hash) && !value.is_a?(Array)
  end
  private_class_method :project_entry, :scalar?
end
