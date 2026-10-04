module Crm::Deals::UpsertAttributes
  private

  def relationship_attributes
    {
      account: account,
      pipeline: @stage.pipeline,
      stage: @stage,
      owner: @owner,
      creator: @creator,
      team: @team,
      company: @company,
      originating_conversation: @conversation,
      originating_communication_thread: @communication_thread
    }
  end

  def content_attributes
    {
      title: resolve_title,
      description: resolve_optional_text(:description, current: deal.description),
      amount_minor: resolve_integer(:amount_minor, current: deal.amount_minor, allow_nil: true),
      currency: resolve_optional_text(:currency, current: deal.currency),
      expected_close_on: resolve_date(:expected_close_on, current: deal.expected_close_on),
      win_probability: resolve_integer(:win_probability, current: deal.win_probability, allow_nil: true)
    }
  end
end
