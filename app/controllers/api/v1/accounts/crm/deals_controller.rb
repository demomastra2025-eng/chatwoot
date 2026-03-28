class Api::V1::Accounts::Crm::DealsController < Api::V1::Accounts::Crm::BaseController
  CREATE_PARAM_KEYS = %i[
    pipeline_id
    stage_id
    owner_id
    creator_id
    team_id
    company_id
    originating_conversation_id
    title
    description
    amount_minor
    currency
    expected_close_on
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
    title
    description
    amount_minor
    currency
    expected_close_on
    win_probability
    external_ref
    idempotency_key
    primary_contact_id
    lock_version
  ].freeze

  before_action :ensure_crm_deals_enabled!
  before_action :bootstrap_defaults!, only: [:index, :create]
  before_action :set_deal, only: [:show, :update, :timeline, :transition_stage, :archive, :unarchive]

  def index
    authorize ::Crm::Deal

    deals = filtered_deals
    render_payload(
      deals.map { |deal| ::Crm::PayloadBuilder.deal(deal) },
      meta: { count: deals.size }
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

    deal = ::Crm::Deals::TransitionService.new(
      account: Current.account,
      deal: @deal,
      params: params.permit(:stage_id, :lock_version),
      actor: Current.user
    ).perform

    render_payload(::Crm::PayloadBuilder.deal(deal))
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

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  def create_deal_params
    params.permit(*CREATE_PARAM_KEYS, contact_ids: [], custom_attributes: {})
  end

  def filter_by_contact(scope)
    return scope if params[:contact_id].blank?

    scope.joins(:deal_contacts).where(crm_deal_contacts: { contact_id: params[:contact_id] }).distinct
  end

  def filter_by_exact(scope, field_name)
    return scope if params[field_name].blank?

    scope.where(field_name => params[field_name])
  end

  def filter_by_query(scope)
    return scope if params[:q].blank?

    query = "%#{params[:q].to_s.strip}%"
    scope.where('crm_deals.title ILIKE :query OR crm_deals.external_ref ILIKE :query', query: query)
  end

  def filtered_deals
    scope = policy_scope(::Crm::Deal).preload(:company, deal_contacts: :contact).ordered
    scope = parse_boolean(params[:archived]) ? scope.archived : scope.kept
    scope = filter_by_exact(scope, :pipeline_id)
    scope = filter_by_exact(scope, :stage_id)
    scope = filter_by_exact(scope, :owner_id)
    scope = filter_by_exact(scope, :team_id)
    scope = filter_by_exact(scope, :company_id)
    scope = filter_by_contact(scope)
    filter_by_query(scope)
  end

  def idempotent_deal
    return if create_deal_params[:idempotency_key].blank?

    Current.account.crm_deals.preload(:company, deal_contacts: :contact).find_by(idempotency_key: create_deal_params[:idempotency_key])
  end

  def set_deal
    @deal = policy_scope(::Crm::Deal).preload(:company, deal_contacts: :contact).find(params[:id])
  end

  def update_deal_params
    params.permit(*UPDATE_PARAM_KEYS, contact_ids: [], custom_attributes: {})
  end
end
