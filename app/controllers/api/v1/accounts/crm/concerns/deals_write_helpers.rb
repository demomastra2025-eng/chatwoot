module Api::V1::Accounts::Crm::Concerns::DealsWriteHelpers
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

  private

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform
  end

  # Read-only requests skip the write-capable bootstrap once it has succeeded recently.
  def bootstrap_defaults_if_needed!
    ::Crm::Bootstrap::AccountService.new(account: Current.account).perform_if_needed
  end

  def create_deal_params
    params.permit(*CREATE_PARAM_KEYS, contact_ids: [], closing_reasons: [], custom_attributes: {})
  end

  def idempotent_deal
    return if create_deal_params[:idempotency_key].blank?

    policy_scope(::Crm::Deal).preload(
      :company,
      :originating_conversation,
      :originating_communication_thread,
      deal_contacts: :contact
    ).find_by(idempotency_key: create_deal_params[:idempotency_key])
  end

  def update_deal_params
    params.permit(*UPDATE_PARAM_KEYS, contact_ids: [], closing_reasons: [], custom_attributes: {})
  end

  def assignment_requested?(permitted_params)
    permitted_params.key?(:owner_id) || permitted_params.key?(:team_id)
  end
end
