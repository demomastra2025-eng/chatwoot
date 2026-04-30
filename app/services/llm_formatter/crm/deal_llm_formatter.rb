module LlmFormatter::Crm
  class DealLlmFormatter < LlmFormatter::DefaultLlmFormatter
    def format(*)
      sections = []
      sections << "Deal ID: ##{@record.id}"
      sections << "Title: #{@record.title}"
      sections << "Description: #{@record.description.presence || 'Not set'}"
      sections << "Pipeline: #{@record.pipeline&.name || 'Not set'}"
      sections << "Stage: #{@record.stage&.name || 'Not set'}"
      sections << "Amount: #{formatted_amount}"
      sections << "Currency: #{@record.currency.presence || 'Not set'}"
      sections << "Expected Close On: #{@record.expected_close_on || 'Not set'}"
      sections << "Win Probability: #{@record.win_probability || 'Not set'}"
      sections << "Owner: #{@record.owner&.name || 'Not set'}"
      sections << "Team: #{@record.team&.name || 'Not set'}"
      sections << "Company: #{@record.company&.name || 'Not set'}"
      sections << "Primary Contact: #{@record.contacts.first&.name || 'Not set'}"
      sections << "Archived: #{@record.archived_at.present?}"
      sections << "Closed At: #{@record.closed_at || 'Not set'}"
      sections << "Custom Attributes: #{@record.custom_attributes.to_json}"
      sections.join("\n")
    end

    private

    def formatted_amount
      amount = Crm::AmountFormatter.major_from_minor(@record.amount_minor)
      return 'Not set' if amount.blank?

      [amount, @record.currency.presence].compact.join(' ')
    end
  end
end
