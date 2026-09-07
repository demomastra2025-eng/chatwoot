class Api::V1::Accounts::Crm::DealsController < Api::V1::Accounts::Crm::BaseController
  DEFAULT_PER_PAGE = 100
  MAX_PER_PAGE = 500
  DEAL_PRELOADS = [
    :company,
    :originating_conversation,
    :originating_communication_thread,
    { deal_contacts: :contact },
    { tasks: :status }
  ].freeze
  BOARD_SORT_COLUMNS = {
    'amount' => 'COALESCE(crm_deals.amount_minor, 0)',
    'createdAt' => 'crm_deals.created_at',
    'expectedCloseOn' => 'crm_deals.expected_close_on',
    'position' => 'crm_deals.position',
    'title' => 'LOWER(crm_deals.title)',
    'updatedAt' => 'crm_deals.updated_at'
  }.freeze

  CREATE_PARAM_KEYS = %i[
    pipeline_id
    stage_id
    owner_id
    creator_id
    team_id
    company_id
    originating_conversation_id
    originating_communication_thread_id
    title
    description
    amount_minor
    currency
    expected_close_on
    position
    win_probability
    external_ref
    idempotency_key
    primary_contact_id
  ].freeze
  UPDATE_PARAM_KEYS = %i[
    owner_id
    creator_id
    team_id
    company_id
    originating_conversation_id
    originating_communication_thread_id
    title
    description
    amount_minor
    currency
    expected_close_on
    position
    win_probability
    external_ref
    idempotency_key
    primary_contact_id
    lock_version
  ].freeze

  before_action :ensure_crm_deals_enabled!
  before_action :bootstrap_defaults!, only: [:index, :create]
  before_action :set_deal, only: [
    :show, :update, :timeline, :transition_stage, :close_won, :close_lost, :reopen, :reorder, :undo_transition,
    :set_waiting, :clear_waiting, :archive, :unarchive
  ]

  def index
    authorize ::Crm::Deal

    deals = filtered_deals
    paginated_deals = board_mode? ? board_page(deals) : deals.offset(page_offset).limit(per_page_param)

    render_payload(
      paginated_deals.map { |deal| ::Crm::PayloadBuilder.deal(deal) },
      meta: pagination_meta(deals, paginated_deals)
    )
  end

  def show
    authorize @deal
    render_payload(::Crm::PayloadBuilder.deal(@deal))
  end

  def create
    authorize ::Crm::Deal

    existing_deal = idempotent_deal
    return render_payload(::Crm::PayloadBuilder.deal(existing_deal)) if existing_deal.present?

    deal = ::Crm::Deals::UpsertService.new(
      account: Current.account,
      params: create_deal_params,
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.deal(deal), status: :created)
  end

  def update
    authorize @deal

    deal = ::Crm::Deals::UpsertService.new(
      account: Current.account,
      params: update_deal_params,
      deal: @deal,
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.deal(deal))
  end

  def timeline
    authorize @deal

    timeline = ::Crm::Timelines::DealService.new(
      account: Current.account,
      deal: @deal,
      actor: Current.user,
      params: params.permit(:before, :limit)
    ).perform

    render_payload(timeline[:items], meta: timeline[:meta])
  end

  def transition_stage
    authorize @deal, :transition_stage?

    deal = ::Crm::Deals::StageCommandService.new(
      account: Current.account,
      deal: @deal,
      params: lifecycle_params,
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.deal(deal))
  end

  def close_won
    perform_lifecycle_command(::Crm::Deals::CloseWonService)
  end

  def close_lost
    perform_lifecycle_command(::Crm::Deals::CloseLostService)
  end

  def reopen
    perform_lifecycle_command(::Crm::Deals::ReopenService)
  end

  def reorder
    perform_lifecycle_command(::Crm::Deals::ReorderService)
  end

  def undo_transition
    perform_lifecycle_command(::Crm::Deals::UndoTransitionService)
  end

  def set_waiting
    perform_waiting_command(::Crm::Deals::SetWaitingService, waiting_params)
  end

  def clear_waiting
    perform_waiting_command(::Crm::Deals::ClearWaitingService, params.permit(:lock_version, :idempotency_key))
  end

  def archive
    authorize @deal, :archive?

    deal = ::Crm::Deals::ArchiveService.new(
      account: Current.account,
      deal: @deal,
      params: params.permit(:lock_version),
      archived: true,
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.deal(deal))
  end

  def unarchive
    authorize @deal, :unarchive?

    deal = ::Crm::Deals::ArchiveService.new(
      account: Current.account,
      deal: @deal,
      params: params.permit(:lock_version),
      archived: false,
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.deal(deal))
  end

  private

  def perform_waiting_command(service_class, command_params)
    authorize @deal, :transition_stage?
    deal = service_class.new(
      account: Current.account,
      deal: @deal,
      params: command_params,
      actor: Current.user
    ).perform
    render_payload(::Crm::PayloadBuilder.deal(deal))
  end

  def perform_lifecycle_command(service_class)
    authorize @deal, :transition_stage?
    deal = service_class.new(
      account: Current.account,
      deal: @deal,
      params: lifecycle_params,
      actor: Current.user
    ).perform
    render_payload(::Crm::PayloadBuilder.deal(deal))
  end

  def lifecycle_params
    params.permit(
      :stage_id,
      :position,
      :lock_version,
      :idempotency_key,
      :event_id,
      :override,
      :override_reason,
      closing_reasons: []
    )
  end

  def waiting_params
    params.permit(
      :waiting_until,
      :waiting_reason,
      :create_wake_up_task,
      :wake_up_task_title,
      :lock_version,
      :idempotency_key
    )
  end

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def create_deal_params
    params.permit(*CREATE_PARAM_KEYS, contact_ids: [], closing_reasons: [], custom_attributes: {})
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
    return scope if params[:q].blank?

    query = "%#{params[:q].to_s.strip}%"
    scope.where('crm_deals.title ILIKE :query OR crm_deals.external_ref ILIKE :query', query: query)
  end

  def filtered_deals
    scope = policy_scope(::Crm::Deal).preload(*DEAL_PRELOADS).ordered
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
    Current.account.crm_tasks.kept
           .joins(:status)
           .where(crm_task_statuses: { category: %w[open in_progress] })
           .where.not(deal_id: nil)
           .select(:deal_id)
  end

  def overdue_task_deal_ids
    open_task_deal_ids.where(
      'crm_tasks.due_at < :now OR crm_tasks.due_on < :today',
      now: Time.zone.now,
      today: Time.zone.today
    )
  end

  def page_param
    value = params[:page].presence || 1
    value.to_i.clamp(1, 10_000)
  end

  def per_page_param
    value = params[:per_page].presence || params[:limit].presence || DEFAULT_PER_PAGE
    value.to_i.clamp(1, MAX_PER_PAGE)
  end

  def page_offset
    (page_param - 1) * per_page_param
  end

  def board_mode?
    parse_boolean(params[:board])
  end

  def board_page(scope)
    ranked_deals = scope.except(:preload).reorder(nil).select('crm_deals.*', Arel.sql(board_row_number_sql))

    ::Crm::Deal
      .with(ranked_deals: ranked_deals)
      .from('ranked_deals AS crm_deals')
      .where(board_row_number: (page_offset + 1)..(page_offset + per_page_param))
      .preload(*DEAL_PRELOADS)
      .reorder(Arel.sql('crm_deals.stage_id ASC, crm_deals.board_row_number ASC'))
  end

  def board_row_number_sql
    <<~SQL.squish
      ROW_NUMBER() OVER (
        PARTITION BY crm_deals.stage_id
        ORDER BY #{board_order_sql}
      ) AS board_row_number
    SQL
  end

  def board_order_sql
    sort_column = BOARD_SORT_COLUMNS.fetch(params[:board_sort].to_s, BOARD_SORT_COLUMNS.fetch('position'))
    return "#{sort_column} ASC NULLS LAST, crm_deals.id ASC" if sort_column == BOARD_SORT_COLUMNS.fetch('position')

    descending_stage_ids = board_sort_directions.filter_map do |stage_id, direction|
      numeric_stage_id = stage_id.to_i
      numeric_stage_id if numeric_stage_id.positive? && direction == 'desc'
    end
    return "#{sort_column} ASC NULLS LAST, crm_deals.id ASC" if descending_stage_ids.empty?

    id_list = descending_stage_ids.join(', ')
    <<~SQL.squish
      CASE WHEN crm_deals.stage_id IN (#{id_list}) THEN #{sort_column} END DESC NULLS LAST,
      CASE WHEN crm_deals.stage_id NOT IN (#{id_list}) THEN #{sort_column} END ASC NULLS LAST,
      crm_deals.id ASC
    SQL
  end

  def board_sort_directions
    raw_directions = params[:board_sort_directions]
    return {} unless raw_directions.respond_to?(:to_unsafe_h)

    raw_directions.to_unsafe_h.transform_values(&:to_s)
  end

  def pagination_meta(scope, records)
    stage_counts = scope.reorder(nil).group(:stage_id).count.transform_keys(&:to_s)
    total_count = stage_counts.values.sum
    paginated_count = board_mode? ? stage_counts.values.max.to_i : total_count
    total_pages = (paginated_count.to_f / per_page_param).ceil

    {
      count: records.size,
      has_more: page_param < total_pages,
      page: page_param,
      per_page: per_page_param,
      stage_counts: stage_counts,
      total_count: total_count,
      total_pages: total_pages
    }
  end

  def idempotent_deal
    return if create_deal_params[:idempotency_key].blank?

    Current.account.crm_deals.preload(
      :company,
      :originating_conversation,
      :originating_communication_thread,
      deal_contacts: :contact
    ).find_by(idempotency_key: create_deal_params[:idempotency_key])
  end

  def set_deal
    @deal = policy_scope(::Crm::Deal).preload(
      :company,
      :originating_conversation,
      :originating_communication_thread,
      deal_contacts: :contact
    ).find(params[:id])
  end

  def resolve_originating_conversation(raw_value)
    value = raw_value.to_s.strip
    return if value.blank?

    Current.account.conversations.find_by(id: value) ||
      Current.account.conversations.find_by(display_id: value)
  end

  def resolve_originating_communication_thread(raw_value)
    value = raw_value.to_s.strip
    return if value.blank?

    CommunicationThread.find_by(account_id: Current.account.id, display_id: value) ||
      CommunicationThread.find_by(account_id: Current.account.id, id: value)
  end

  def update_deal_params
    params.permit(*UPDATE_PARAM_KEYS, contact_ids: [], closing_reasons: [], custom_attributes: {})
  end
end
