module Api::V1::Accounts::Crm::Concerns::DealsIndexFiltering
  private

  def deal_preloads
    self.class::DEAL_PRELOADS
  end

  def filter_by_ai_only(scope)
    return scope unless parse_boolean(params[:ai_only])

    pending_conversation_ids = Current.account.conversations.pending.select(:id)
    pending_thread_ids = CommunicationThread.pending.where(account_id: Current.account.id).select(:id)

    scope.where(originating_communication_thread_id: pending_thread_ids)
         .or(
           scope.where(
             originating_communication_thread_id: nil,
             originating_conversation_id: pending_conversation_ids
           )
         )
  end

  def filter_by_contact(scope)
    return scope if params[:contact_id].blank?

    scope.joins(:deal_contacts).where(crm_deal_contacts: { contact_id: params[:contact_id] }).distinct
  end

  def filter_by_exact(scope, field_name)
    return scope if params[field_name].blank?

    scope.where(field_name => params[field_name])
  end

  def filter_by_created_range(scope)
    from = parse_datetime_param!(params[:created_from], field_name: 'created_from', required: false)
    to = parse_datetime_param!(params[:created_to], field_name: 'created_to', required: false)
    return scope if from.blank? && to.blank?

    scoped = scope
    scoped = scoped.where('crm_deals.created_at >= ?', from) if from.present?
    scoped = scoped.where('crm_deals.created_at <= ?', to) if to.present?
    scoped
  end

  def filter_by_originating_conversation(scope)
    return scope if params[:originating_conversation_id].blank?

    conversation = resolve_originating_conversation(params[:originating_conversation_id])
    return scope.none if conversation.blank?

    scope.where(originating_conversation_id: conversation.id)
  end

  def filter_by_originating_communication_thread(scope)
    return scope if params[:originating_communication_thread_id].blank?

    communication_thread = resolve_originating_communication_thread(params[:originating_communication_thread_id])
    return scope.none if communication_thread.blank?

    scope.where(originating_communication_thread_id: communication_thread.id)
  end

  def filter_by_query(scope)
    ::Crm::Deals::SearchQuery.new(scope: scope, params: params).perform
  end

  def filtered_deals
    scope = policy_scope(::Crm::Deal).preload(*deal_preloads).ordered
    scope = parse_boolean(params[:archived]) ? scope.archived : scope.kept
    %i[pipeline_id stage_id owner_id team_id company_id].each do |field_name|
      scope = filter_by_exact(scope, field_name)
    end
    scope = filter_by_originating_conversation(scope)
    scope = filter_by_ai_only(filter_by_originating_communication_thread(scope))
    scope = filter_by_contact(scope)
    scope = filter_by_next_action(scope)
    scope = filter_by_query(filter_by_created_range(scope))

    ::Crm::CustomFieldFilterSet.new(
      account: Current.account,
      entity_kind: 'deal',
      raw_filters: custom_attribute_filters_param
    ).apply(scope)
  end

  def filter_by_next_action(scope)
    case params[:next_action].to_s
    when '' then scope
    when 'overdue' then scope.where(waiting_until: nil, closed_at: nil).where(id: overdue_task_deal_ids)
    when 'no_action' then scope.where(waiting_until: nil, closed_at: nil).where.not(id: open_task_deal_ids)
    when 'waiting_expired' then scope.where(closed_at: nil).where(waiting_until: ..Time.zone.now)
    else
      raise Crm::Error.new(
        code: 'VALIDATION_ERROR',
        message: 'next_action is invalid',
        status: :unprocessable_content,
        details: { next_action: ['is invalid'] }
      )
    end
  end

  def open_task_deal_ids
    policy_scope(::Crm::Task).kept
                             .joins(:status)
                             .where(crm_task_statuses: { category: %w[open in_progress] })
                             .where.not(deal_id: nil)
                             .select(:deal_id)
  end

  def overdue_task_deal_ids
    open_task_deal_ids.where(
      'crm_tasks.due_at < :now OR crm_tasks.due_on < :today',
      now: Time.current,
      today: Time.find_zone!(Crm::WorkspaceTimezone.resolve(Current.account)).today
    )
  end
end
