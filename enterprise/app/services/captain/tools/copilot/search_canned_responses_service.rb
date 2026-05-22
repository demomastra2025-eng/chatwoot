class Captain::Tools::Copilot::SearchCannedResponsesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_canned_responses'
  end

  description 'Search canned responses by short code or response content'
  param :query, type: :string, desc: 'Optional search text', required: false
  param :limit, type: :integer, desc: 'Maximum number of canned responses to return', required: false

  def execute(query: nil, limit: nil)
    responses = canned_responses_scope(query: query)
    total_count = responses.count

    formatted_payload(
      filters: { query: query.presence }.compact,
      total_count: total_count,
      canned_responses: responses.limit(parse_limit(limit)).map { |response| canned_response_payload(response) }
    )
  end

  def active?
    current_account_user.present?
  end

  private

  def canned_responses_scope(query:)
    scope = account.canned_responses.order(:short_code, :id)
    return scope if query.blank?

    scope.where('short_code ILIKE :search OR content ILIKE :search', search: "%#{query}%").order_by_search(query)
  end

  def canned_response_payload(response)
    {
      id: response.id,
      short_code: response.short_code,
      content: response.content,
      created_at: response.created_at&.iso8601,
      updated_at: response.updated_at&.iso8601
    }
  end
end
