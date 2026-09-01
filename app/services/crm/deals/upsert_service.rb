class Crm::Deals::UpsertService < Crm::BaseWriteService
  def initialize(account:, params:, deal: nil, actor: nil)
    @deal = deal || account.crm_deals.new
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    realtime_event_name = nil
    realtime_meta = {}
    saved_deal = ApplicationRecord.transaction do
      bootstrap_defaults!
      assert_lock_version!

      new_record = deal.new_record?
      requested_position = resolve_requested_position
      stage = resolve_stage!
      stage_changing = new_record || deal.stage_id != stage.id
      pipeline = stage.pipeline
      conversation = resolve_originating_conversation
      communication_thread = resolve_originating_communication_thread
      validate_source_contacts!(conversation: conversation, communication_thread: communication_thread)
      contacts, primary_contact = resolve_contacts(conversation: conversation, communication_thread: communication_thread)
      company = resolve_company(current_contacts: contacts, primary_contact: primary_contact)
      owner = resolve_deal_owner(conversation: conversation, communication_thread: communication_thread, primary_contact: primary_contact)
      creator = resolve_optional_record(:creator_id, account.users, current: deal.creator || actor)
      team = resolve_optional_record(:team_id, account.teams, current: deal.team)
      external_ref = resolve_optional_text(:external_ref, current: deal.external_ref)
      idempotency_key = resolve_optional_text(:idempotency_key, current: deal.idempotency_key)

      ensure_unique_reference!(scope: account.crm_deals, attribute: :external_ref, value: external_ref, code: 'DUPLICATE_EXTERNAL_REF')
      ensure_unique_reference!(scope: account.crm_deals, attribute: :idempotency_key, value: idempotency_key, code: 'DUPLICATE_IDEMPOTENCY_KEY')

      custom_attributes = field_catalog.resolve_custom_attributes(
        current_attributes: deal.custom_attributes,
        incoming_attributes: params[:custom_attributes],
        apply_defaults: new_record
      )
      closing_reasons = resolve_closing_reasons!(
        target_stage: stage,
        current_reasons: deal.closing_reasons,
        require_input: stage_changing
      )
      transition_reason = resolve_transition_reason!(
        target_stage: stage,
        require_input: !new_record && stage_changing
      )

      deal.assign_attributes(
        account: account,
        pipeline: pipeline,
        stage: stage,
        owner: owner,
        creator: creator,
        team: team,
        company: company,
        originating_conversation: conversation,
        originating_communication_thread: communication_thread,
        title: resolve_title,
        description: resolve_optional_text(:description, current: deal.description),
        amount_minor: resolve_integer(:amount_minor, current: deal.amount_minor, allow_nil: true),
        currency: resolve_optional_text(:currency, current: deal.currency),
        expected_close_on: resolve_date(:expected_close_on, current: deal.expected_close_on),
        win_probability: resolve_integer(:win_probability, current: deal.win_probability, allow_nil: true),
        external_ref: external_ref,
        idempotency_key: idempotency_key,
        custom_attributes: custom_attributes,
        closing_reasons: closing_reasons
      )
      deal.position = requested_position if requested_position.present?
      deal.closed_at = resolve_closed_at(stage: stage, stage_changing: stage_changing)
      deal.save!
      sync_incomplete_task_teams! if deal.saved_change_to_team_id?
      auto_apply_default_touch_plan! if new_record
      reposition_deal!(requested_position) if requested_position.present?

      contacts_changed = sync_contacts!(contacts: contacts, primary_contact: primary_contact)
      sync_related_touches!
      sync_owner_to_primary_contact!(primary_contact)
      realtime_event_name = realtime_event_name_for(
        new_record: new_record,
        contacts_changed: contacts_changed
      )
      realtime_meta = realtime_event_meta(
        new_record: new_record,
        contacts_changed: contacts_changed
      )
      write_event!(new_record: new_record, contacts_changed: contacts_changed, transition_reason: transition_reason)
      notify_assignment!(new_record: new_record)

      deal.reload
    end

    if realtime_event_name.present?
      dispatch_crm_deal_realtime_event!(
        realtime_event_name,
        saved_deal,
        meta: realtime_meta
      )
    end
    saved_deal
  end

  private

  attr_reader :deal

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: account).perform if account.feature_enabled?('crm_deals')
  end

  def field_catalog
    @field_catalog ||= ::Crm::FieldCatalog.new(account: account, entity_kind: 'deal')
  end

  def resolve_closed_at(stage:, stage_changing:)
    return deal.closed_at unless stage_changing

    stage.outcome_open? ? nil : Time.zone.now
  end

  def resolve_company(current_contacts:, primary_contact:)
    company = resolve_optional_record(:company_id, account.companies, current: deal.company)
    return company if company.present? || params.key?(:company_id)

    primary_contact&.company || current_contacts.first&.company
  end

  def resolve_contacts(conversation:, communication_thread:)
    source_contact = communication_thread&.contact || conversation&.contact
    contacts = if params.key?(:contact_ids)
                 resolve_many_records(account.contacts, params[:contact_ids])
               else
                 deal.contacts.to_a
               end

    primary_contact = if params.key?(:primary_contact_id)
                        resolve_optional_record(:primary_contact_id, account.contacts, current: nil)
                      elsif contacts.blank? && source_contact.present?
                        source_contact
                      else
                        deal.deal_contacts.find(&:primary?)&.contact || contacts.first
                      end

    contacts |= [primary_contact].compact
    [contacts, primary_contact]
  end

  def resolve_stage!
    return account.crm_stages.find(params[:stage_id]) if params.key?(:stage_id) && params[:stage_id].present?
    return deal.stage if deal.persisted?

    pipeline = if params.key?(:pipeline_id) && params[:pipeline_id].present?
                 account.crm_pipelines.find(params[:pipeline_id])
               else
                 account.crm_pipelines.active.find_by(default: true) ||
                   account.crm_pipelines.active.ordered.first
               end

    validation_error!('pipeline_id', 'must reference an active pipeline') if pipeline.blank?

    pipeline.stages.active.find_by(default: true) || pipeline.stages.active.find_by(outcome: 'open') ||
      pipeline.stages.active.ordered.first ||
      validation_error!('stage_id', 'must reference an active stage')
  end

  def resolve_title
    title = resolve_optional_text(:title, current: deal.title)
    validation_error!('title', 'is required') if title.blank?

    title
  end

  def resolve_deal_owner(conversation:, communication_thread:, primary_contact:)
    return resolve_optional_record(:owner_id, account.users, current: deal.owner) if params.key?(:owner_id)
    return deal.owner if deal.persisted?

    default_owner_for_source(conversation: conversation, communication_thread: communication_thread, primary_contact: primary_contact)
  end

  def default_owner_for_source(conversation:, communication_thread:, primary_contact:)
    source_owner_candidates(
      conversation: conversation,
      communication_thread: communication_thread,
      primary_contact: primary_contact
    ).find(&:present?) || actor
  end

  def source_owner_candidates(conversation:, communication_thread:, primary_contact:)
    contact_owner = primary_contact&.owner || communication_thread&.contact&.owner || conversation&.contact&.owner
    return [contact_owner, conversation&.assignee, communication_thread&.assignee] if params[:originating_communication_thread_id].blank?

    [
      contact_owner,
      communication_thread&.assignee,
      default_owner_from_thread_conversations(communication_thread),
      conversation&.assignee
    ]
  end

  def default_owner_from_thread_conversations(communication_thread)
    return if communication_thread.blank?

    communication_thread.conversations
                        .where.not(assignee_id: nil)
                        .order(Arel.sql('conversations.last_activity_at DESC NULLS LAST, conversations.id DESC'))
                        .first&.assignee
  end

  def resolve_requested_position
    return unless params.key?(:position)

    resolve_integer(:position, current: deal.position, allow_nil: true)
  end

  def reposition_deal!(requested_position)
    ::Crm::BoardPositioner.place!(
      scope: account.crm_deals.kept.where(stage_id: deal.stage_id),
      record: deal,
      target_position: requested_position
    )
  end

  def sync_contacts!(contacts:, primary_contact:)
    existing_links = deal.deal_contacts.index_by(&:contact_id)
    desired_contact_ids = contacts.map(&:id)
    changed = false

    deal.deal_contacts.where.not(contact_id: desired_contact_ids).find_each do |deal_contact|
      changed = true
      deal_contact.destroy!
    end

    contacts.each do |contact|
      deal_contact = existing_links[contact.id] || deal.deal_contacts.new(account: account, contact: contact)
      next unless deal_contact.new_record? || deal_contact.primary != (contact.id == primary_contact&.id)

      changed = true
      deal_contact.update!(account: account, contact: contact, primary: contact.id == primary_contact&.id)
    end

    changed
  end

  def sync_owner_to_primary_contact!(primary_contact)
    return if primary_contact.blank?
    return if primary_contact.owner_id == deal.owner_id

    primary_contact.update!(owner_id: deal.owner_id)
  end

  def sync_incomplete_task_teams!
    tasks = deal.tasks
                .kept
                .joins(:status)
                .where(crm_task_statuses: { category: %w[open in_progress] })
    tasks = if deal.team_id.present?
              tasks.where.not(team_id: deal.team_id).or(tasks.where(team_id: nil))
            else
              tasks.where.not(team_id: nil)
            end

    tasks.find_each do |task|
      ::Crm::Tasks::UpsertService.new(
        account: account,
        actor: actor,
        params: { lock_version: task.lock_version },
        task: task
      ).perform
    end
  end

  def resolve_originating_conversation
    return deal.originating_conversation unless params.key?(:originating_conversation_id)
    return nil if params[:originating_conversation_id].blank?

    value = params[:originating_conversation_id].to_s.strip

    account.conversations.find_by(id: value) ||
      account.conversations.find_by!(display_id: value)
  end

  def resolve_originating_communication_thread
    if params.key?(:originating_communication_thread_id)
      return resolve_originating_communication_thread_by_value(
        params[:originating_communication_thread_id]
      )
    end

    deal.originating_communication_thread if deal.persisted?
  end

  def resolve_originating_communication_thread_by_value(raw_value)
    return nil if raw_value.blank?

    value = raw_value.to_s.strip
    scope = CommunicationThread.where(account_id: account.id)
    scope.find_by(display_id: value) || scope.find(value)
  end

  def validate_source_contacts!(conversation:, communication_thread:)
    return if conversation.blank? || communication_thread.blank?
    return if conversation.contact_id == communication_thread.contact_id

    validation_error!(
      'originating_communication_thread_id',
      'must reference the same contact as originating_conversation_id'
    )
  end

  def write_event!(new_record:, contacts_changed:, transition_reason: nil)
    return unless new_record || contacts_changed || filtered_previous_changes.present?

    meta = {
      changes: filtered_previous_changes,
      contact_ids: deal.deal_contacts.ordered.pluck(:contact_id),
      primary_contact_id: deal.primary_contact_id
    }
    meta[:transition_reason] = transition_reason if transition_reason.present?

    ::Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: new_record ? 'deal_created' : 'deal_updated',
      meta: meta
    )
  end

  def notify_assignment!(new_record:)
    return unless new_record || deal.previous_changes.key?('owner_id')

    ::Crm::AssignmentNotificationService.new(
      account: account,
      record: deal,
      user: deal.owner,
      notification_type: 'deal_assignment',
      actor: actor
    ).perform
  end

  def realtime_event_name_for(new_record:, contacts_changed:)
    return Events::Types::CRM_DEAL_CREATED if new_record
    return Events::Types::CRM_DEAL_UPDATED if contacts_changed || filtered_previous_changes.present?

    nil
  end

  def realtime_event_meta(new_record:, contacts_changed:)
    {
      changes: filtered_previous_changes,
      contacts_changed: contacts_changed,
      event_type: new_record ? 'deal_created' : 'deal_updated'
    }
  end

  def auto_apply_default_touch_plan!
    Reminders::DefaultPlanService.new(
      account: account,
      remindable: deal,
      actor: actor
    ).perform
  end

  def sync_related_touches!
    Reminders::SyncRemindableService.new(remindable: deal).perform
  end
end
