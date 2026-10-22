class Api::V1::Accounts::Crm::DealsController < Api::V1::Accounts::Crm::BaseController
  include ::Api::V1::Accounts::Crm::Concerns::DealsIndexFiltering
  include ::Api::V1::Accounts::Crm::Concerns::DealsOriginResolvers
  include ::Api::V1::Accounts::Crm::Concerns::DealsBoarding
  include ::Api::V1::Accounts::Crm::Concerns::DealsLifecycleCommands
  include ::Api::V1::Accounts::Crm::Concerns::DealsWriteHelpers
  DEAL_PRELOADS = [
    :account, :stage, :company, :originating_conversation, :originating_communication_thread,
    { deal_contacts: :contact }, { tasks: [:status, :task_type, :task_outcome] }
  ].freeze
  before_action :ensure_crm_deals_enabled!
  before_action :bootstrap_defaults_if_needed!, only: :index
  before_action :bootstrap_defaults!, only: :create
  before_action :set_deal, only: [
    :show, :update, :timeline, :transition_stage, :close_won, :close_lost, :reopen, :reorder, :undo_transition,
    :set_waiting, :clear_waiting, :archive, :unarchive, :destroy,
    :appointments, :resume_appointment_automation
  ]

  def index
    authorize ::Crm::Deal

    deals = filtered_deals
    deals = visible_board_deals(deals) if board_mode?
    list_page = ::Crm::Deals::ListOrderService.new(
      scope: deals,
      page: page_param,
      per_page: per_page_param,
      sort_by: params[:sort_by],
      sort_direction: params[:sort_direction]
    )
    paginated_deals = board_mode? ? board_page(deals) : list_page.perform
    catalog_snapshot = ::Crm::Tasks::CatalogSnapshot.new(account: Current.account)

    render_payload(
      paginated_deals.map { |deal| ::Crm::PayloadBuilder.deal(deal, catalog_snapshot: catalog_snapshot) },
      meta: pagination_meta(deals, paginated_deals)
    )
  end

  def show
    authorize @deal
    render_payload(::Crm::PayloadBuilder.deal(@deal))
  end

  def appointment_options
    authorize ::Crm::Deal, :index?
    contact = Current.account.contacts.find(params[:contact_id]) if params[:contact_id].present?
    if params[:conversation_display_id].present?
      conversation = Current.account.conversations.find_by!(display_id: params[:conversation_display_id])
      raise ArgumentError, 'Conversation contact does not match' if contact && conversation.contact_id != contact.id

      contact ||= conversation.contact
    end
    deals = ::Crm::Appointments::CandidateScope.resolve(account: Current.account, contact: contact).includes(:pipeline).order(:id).limit(100)
    rows = deals.map do |deal|
      { id: deal.id, title: deal.title, pipeline_id: deal.pipeline_id, pipeline_name: deal.pipeline.name,
        cardinality: ::Crm::Appointments::Configuration.for(deal.pipeline)['cardinality'] }
    end
    source = rows.find { |row| row[:id] == params[:source_deal_id].to_i }
    pipelines = Current.account.crm_pipelines.active.ordered.map do |pipeline|
      { id: pipeline.id, name: pipeline.name, auto_create: pipeline.auto_create_deal_on_channel_contact, default: pipeline.default? }
    end
    render_payload({ deals: rows, pipelines: pipelines, automatic_deal_id: source&.fetch(:id) || (rows.one? ? rows.first[:id] : nil),
                     requires_selection: rows.many? && !source })
  end

  def appointments
    authorize @deal, :show?
    payload = Scheduling::PayloadBuilder.appointments(@deal.appointments.where(account_id: Current.account.id).includes(:resource, :contact,
                                                                                                                        :patient_contact).ordered)
    render_payload(payload, meta: { timezone: ::Crm::Appointments::Facts.timezone_for(Current.account).tzinfo.name })
  end

  def resume_appointment_automation
    authorize @deal, :update?
    @deal.with_lock do
      raise ActiveRecord::StaleObjectError.new(@deal, 'resume') unless params.key?(:lock_version) && params[:lock_version].to_i == @deal.lock_version

      previous_state = @deal.appointment_automation_state
      @deal.appointment_automation_state = @deal.appointment_automation_state.to_h.except('paused_at', 'manual_fingerprint', 'evaluated_fingerprint')
      ::Crm::Appointments::DeliveryPolicy.stamp_in_memory!(@deal)
      @deal.save!
      ::Crm::Events::Writer.record!(account: Current.account, eventable: @deal, actor: Current.user, event_type: 'deal_updated',
                                    before_data: { appointment_automation_state: previous_state.to_h.except(::Crm::Appointments::DeliveryPolicy::KEY) },
                                    after_data: { appointment_automation_state: @deal.appointment_automation_state.to_h.except(::Crm::Appointments::DeliveryPolicy::KEY) },
                                    meta: { appointment_automation_resumed: true })
    end
    ::Crm::Appointments::EvaluateDealJob.perform_later(Current.account.id, @deal.id)
    render_payload(::Crm::PayloadBuilder.deal(@deal))
  end

  def create
    authorize ::Crm::Deal
    authorize ::Crm::Deal, :assign? if assignment_requested?(create_deal_params)

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
    authorize @deal, :assign? if assignment_requested?(update_deal_params)

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

def destroy
  authorize @deal, :destroy?
  @deal.destroy!
  head :no_content
end

def bulk_action
  authorize ::Crm::Deal, :bulk_action?

  deal_ids = Array(params[:deal_ids]).map(&:to_i).select(&:positive?).uniq
  action_type = params[:action_type].to_s
  raise ArgumentError, "Unsupported bulk action: #{action_type}" unless %w[transition_stage assign_owner archive unarchive delete].include?(action_type)
  return render_payload({ count: 0, deal_ids: [] }) if deal_ids.empty?

  scoped_deals = policy_scope(::Crm::Deal).where(id: deal_ids).to_a
  processed_ids = []

  ActiveRecord::Base.transaction do
    scoped_deals.each do |deal|
      case action_type
      when "delete"
        authorize deal, :destroy?
        deal.destroy!
        processed_ids << deal.id
      when "archive", "unarchive"
        authorize deal, (action_type == "archive" ? :archive? : :unarchive?)
        ::Crm::Deals::ArchiveService.new(
          account: Current.account,
          deal: deal,
          params: { lock_version: deal.lock_version },
          archived: (action_type == "archive"),
          actor: Current.user
        ).perform
        processed_ids << deal.id
      when "assign_owner"
        authorize deal, :assign?
        raw_owner = params[:owner_id]
        owner_id = raw_owner.present? && raw_owner.to_s != "0" ? raw_owner.to_i : nil
        ::Crm::Deals::UpsertService.new(
          account: Current.account,
          deal: deal,
          params: { owner_id: owner_id, lock_version: deal.lock_version },
          actor: Current.user
        ).perform
        processed_ids << deal.id
      when "transition_stage"
        authorize deal, :transition_stage?
        target_stage_id = params[:stage_id].to_i
        raise ArgumentError, "stage_id is required" unless target_stage_id.positive?

        if deal.stage_id != target_stage_id
          ::Crm::Deals::StageCommandService.new(
            account: Current.account,
            deal: deal,
            params: {
              stage_id: target_stage_id,
              lock_version: deal.lock_version,
              override_stage_rules: true,
              override_reason: "bulk_action"
            },
            actor: Current.user
          ).perform
        end
        processed_ids << deal.id
      end
    end
  end

  render_payload({ action_type: action_type, count: processed_ids.size, deal_ids: processed_ids })
end

  private

  def set_deal
    @deal = policy_scope(::Crm::Deal).preload(*DEAL_PRELOADS).find(params[:id])
  end
end
