class Api::V1::Accounts::Crm::DealsController < Api::V1::Accounts::Crm::BaseController
  include ::Api::V1::Accounts::Crm::Concerns::DealsIndexFiltering
  include ::Api::V1::Accounts::Crm::Concerns::DealsOriginResolvers
  include ::Api::V1::Accounts::Crm::Concerns::DealsBoarding
  include ::Api::V1::Accounts::Crm::Concerns::DealsLifecycleCommands
  include ::Api::V1::Accounts::Crm::Concerns::DealsWriteHelpers
  DEAL_PRELOADS = [
    :company,
    :originating_conversation,
    :originating_communication_thread,
    { deal_contacts: :contact },
    { tasks: :status }
  ].freeze
  before_action :ensure_crm_deals_enabled!
  before_action :bootstrap_defaults_if_needed!, only: :index
  before_action :bootstrap_defaults!, only: :create
  before_action :set_deal, only: [
    :show, :update, :timeline, :transition_stage, :close_won, :close_lost, :reopen, :reorder, :undo_transition,
    :set_waiting, :clear_waiting, :archive, :unarchive
  ]

  def index
    authorize ::Crm::Deal

    deals = filtered_deals
    list_page = ::Crm::Deals::ListOrderService.new(
      scope: deals,
      page: page_param,
      per_page: per_page_param,
      sort_by: params[:sort_by],
      sort_direction: params[:sort_direction]
    )
    paginated_deals = board_mode? ? board_page(deals) : list_page.perform

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

  private

  def set_deal
    @deal = policy_scope(::Crm::Deal).preload(
      :company,
      :originating_conversation,
      :originating_communication_thread,
      deal_contacts: :contact
    ).find(params[:id])
  end
end
