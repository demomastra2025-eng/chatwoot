class Crm::Deals::UpsertService < Crm::BaseWriteService
  include Crm::Deals::UpsertContacts
  include Crm::Deals::UpsertEvents
  include Crm::Deals::UpsertOwnership
  include Crm::Deals::UpsertResolution

  def initialize(account:, params:, deal: nil, actor: nil)
    @deal = deal || account.crm_deals.new
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    @correlation_id = SecureRandom.uuid
    saved_deal = ApplicationRecord.transaction { persist_deal! }
    publish_saved_deal(saved_deal) if @realtime_event_name.present?
    saved_deal
  end

  private

  attr_reader :deal

  def persist_deal!
    bootstrap_defaults!
    assert_lock_version!
    resolve_deal_context!
    initialize_existing_stage_visit!
    assign_deal_attributes!
    deal.save!
    finalize_deal!
  end

  def resolve_deal_context!
    resolve_stage_context!
    resolve_source_context!
    resolve_assignment_context!
    resolve_reference_context!
    resolve_custom_context!
  end

  def resolve_stage_context!
    @new_record = deal.new_record?
    @requested_position = resolve_requested_position
    @stage = resolve_stage!
    @stage_changing = @new_record || deal.stage_id != @stage.id
  end

  def resolve_source_context!
    @conversation = resolve_originating_conversation
    @communication_thread = resolve_originating_communication_thread
    validate_source_contacts!(conversation: @conversation, communication_thread: @communication_thread)
    @contacts, @primary_contact = resolve_contacts(
      conversation: @conversation,
      communication_thread: @communication_thread
    )
  end

  def resolve_assignment_context!
    @company = resolve_company(current_contacts: @contacts, primary_contact: @primary_contact)
    @owner = resolve_deal_owner(
      conversation: @conversation,
      communication_thread: @communication_thread,
      primary_contact: @primary_contact
    )
    @creator = resolve_optional_record(:creator_id, account.users, current: deal.creator || actor)
    @team = resolve_optional_record(:team_id, account.teams, current: deal.team)
  end

  def resolve_reference_context!
    @external_ref = resolve_optional_text(:external_ref, current: deal.external_ref)
    @idempotency_key = resolve_optional_text(:idempotency_key, current: deal.idempotency_key)
    ensure_unique_reference!(
      scope: account.crm_deals, attribute: :external_ref, value: @external_ref, code: 'DUPLICATE_EXTERNAL_REF'
    )
    ensure_unique_reference!(
      scope: account.crm_deals, attribute: :idempotency_key, value: @idempotency_key, code: 'DUPLICATE_IDEMPOTENCY_KEY'
    )
  end

  def resolve_custom_context!
    @custom_attributes = field_catalog.resolve_custom_attributes(
      current_attributes: deal.custom_attributes,
      incoming_attributes: params[:custom_attributes],
      apply_defaults: @new_record
    )
    @closing_reasons = resolve_closing_reasons!(
      target_stage: @stage,
      current_reasons: deal.closing_reasons,
      require_input: @stage_changing
    )
  end

  def initialize_existing_stage_visit!
    return unless @stage_changing && deal.persisted?

    ::Crm::StageVisits::Tracker.ensure_initial!(
      deal: deal,
      correlation_id: @correlation_id,
      estimated: true
    )
  end

  def assign_deal_attributes!
    deal.assign_attributes(
      relationship_attributes
        .merge(content_attributes)
        .merge(reference_attributes)
    )
    deal.position = @requested_position if @requested_position.present?
    deal.closed_at = resolve_closed_at(stage: @stage, stage_changing: @stage_changing)
  end

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

  def reference_attributes
    {
      external_ref: @external_ref,
      idempotency_key: @idempotency_key,
      custom_attributes: @custom_attributes,
      closing_reasons: @closing_reasons
    }
  end

  def finalize_deal!
    apply_post_save_updates!
    @contacts_changed = sync_contacts!(contacts: @contacts, primary_contact: @primary_contact)
    sync_related_touches!
    sync_owner_to_primary_contact!(@primary_contact)
    capture_realtime_event!
    write_event!(new_record: @new_record, contacts_changed: @contacts_changed, correlation_id: @correlation_id)
    notify_assignment!(new_record: @new_record)
    deal.reload
  end

  def apply_post_save_updates!
    track_stage_visit!(new_record: @new_record, correlation_id: @correlation_id) if @stage_changing
    sync_incomplete_task_teams! if deal.saved_change_to_team_id?
    auto_apply_default_touch_plan! if @new_record
    reposition_deal!(@requested_position) if @requested_position.present?
  end

  def capture_realtime_event!
    @realtime_event_name = realtime_event_name_for(new_record: @new_record, contacts_changed: @contacts_changed)
    @realtime_meta = realtime_event_meta(new_record: @new_record, contacts_changed: @contacts_changed)
  end

  def publish_saved_deal(saved_deal)
    dispatch_crm_deal_realtime_event!(@realtime_event_name, saved_deal, meta: @realtime_meta)
  end

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: account).perform if account.feature_enabled?('crm_deals')
  end
end
