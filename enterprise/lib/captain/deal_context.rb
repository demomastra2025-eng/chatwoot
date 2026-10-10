class Captain::DealContext
  ACTIVE_SQL = "crm_deals.archived_at IS NULL AND crm_deals.closed_at IS NULL AND crm_stages.outcome = 'open'".freeze
  HISTORY_ORDER_SQL = 'COALESCE(GREATEST(crm_deals.closed_at, crm_deals.archived_at), crm_deals.created_at) DESC, crm_deals.id DESC'.freeze

  def initialize(account:, conversation: nil, contact_id: nil)
    @account = account
    @conversation = conversation
    @contact_id = contact_id || conversation&.contact_id
  end

  def deals
    scope = @account.crm_deals
    return scope.none if @conversation && @conversation.account_id != @account.id
    return scope.none unless @account.contacts.exists?(id: @contact_id)

    scope.where(id: Crm::DealContact.where(account_id: @account.id, contact_id: @contact_id).select(:deal_id))
  end

  def summary
    scope = deals.joins(:stage)
    groups = Captain::ContextSummary::DEAL_GROUPS.map do |key, config|
      group_scope = key == :active ? scope.where(ACTIVE_SQL) : scope.where("NOT (#{ACTIVE_SQL})")
      total = group_scope.count
      order = key == :active ? 'crm_deals.updated_at DESC, crm_deals.id DESC' : HISTORY_ORDER_SQL
      items = group_scope.reorder(Arel.sql(order)).limit(config[:limit]).includes(:pipeline, :stage).map { |record| card(record) }
      Captain::ContextSummary.group(key: key, total: total, items: items, config: config)
    end
    Captain::ContextSummary.build(kind: 'deals', groups: groups, contact_id: @contact_id)
  end

  def card(deal)
    Captain::ContextSummary.deal_card(
      deal.attributes.merge(
        pipeline_name: deal.pipeline&.name, stage_name: deal.stage&.name, stage_outcome: deal.stage&.outcome,
        amount: Crm::AmountFormatter.major_from_minor(deal.amount_minor),
        updated_at: deal.updated_at&.iso8601, created_at: deal.created_at&.iso8601,
        closed_at: deal.closed_at&.iso8601, archived_at: deal.archived_at&.iso8601
      )
    )
  end
end
