class LlmFormatter::CompanyLlmFormatter < LlmFormatter::DefaultLlmFormatter
  def format(*)
    <<~TEXT.strip
      Company ID: ##{@record.id}
      Name: #{@record.name}
      Domain: #{@record.domain.presence || 'Not set'}
      Description: #{@record.description.presence || 'Not set'}
      Contacts Count: #{@record.contacts_count || 0}
      Created At: #{@record.created_at}
      Updated At: #{@record.updated_at}
    TEXT
  end
end
