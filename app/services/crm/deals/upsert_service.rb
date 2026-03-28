class Crm::Deals::UpsertService < Crm::BaseWriteService
  def initialize(account:, params:, deal: nil, actor: nil)
    @deal = deal || account.crm_deals.new
    super(account: account, params: params, record: @deal, actor: actor)
  end

  def perform
    ApplicationRecord.transaction do
      bootstrap_defaults!
      assert_lock_version!

      new_record = deal.new_record?
      stage = resolve_stage!
      pipeline = stage.pipeline
      conversation = resolve_optional_record(:originating_conversation_id, account.conversations, current: deal.originating_conversation)
      contacts, primary_contact = resolve_contacts(conversation: conversation)
      company = resolve_company(current_contacts: contacts, primary_contact: primary_contact)
      owner = resolve_optional_record(:owner_id, account.users, current: deal.owner)
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

      deal.assign_attributes(
        account: account,
        pipeline: pipeline,
        stage: stage,
        owner: owner,
        creator: creator,
        team: team,
        company: company,
        originating_conversation: conversation,
        title: resolve_title,
        description: resolve_optional_text(:description, current: deal.description),
        amount_minor: resolve_integer(:amount_minor, current: deal.amount_minor, allow_nil: true),
        currency: resolve_optional_text(:currency, current: deal.currency),
        expected_close_on: resolve_date(:expected_close_on, current: deal.expected_close_on),
        win_probability: resolve_integer(:win_probability, current: deal.win_probability, allow_nil: true),
        external_ref: external_ref,
        idempotency_key: idempotency_key,
        custom_attributes: custom_attributes
      )
      deal.closed_at = resolve_closed_at(stage: stage)
      deal.save!

      contacts_changed = sync_contacts!(contacts: contacts, primary_contact: primary_contact)
      write_event!(new_record: new_record, contacts_changed: contacts_changed)

      deal.reload
    end
  end

  private

  attr_reader :deal

  def bootstrap_defaults!
    ::Crm::Bootstrap::AccountService.new(account: account).perform if account.feature_enabled?('crm_deals')
  end

  def field_catalog
    @field_catalog ||= ::Crm::FieldCatalog.new(account: account, entity_kind: 'deal')
  end

  def resolve_closed_at(stage:)
    return deal.closed_at unless deal.new_record?

    stage.outcome_open? ? nil : Time.zone.now
  end

  def resolve_company(current_contacts:, primary_contact:)
    company = resolve_optional_record(:company_id, account.companies, current: deal.company)
    return company if company.present? || params.key?(:company_id)

    primary_contact&.company || current_contacts.first&.company
  end

  def resolve_contacts(conversation:)
    contacts = if params.key?(:contact_ids)
                 resolve_many_records(account.contacts, params[:contact_ids])
               else
                 deal.contacts.to_a
               end

    primary_contact = if params.key?(:primary_contact_id)
                        resolve_optional_record(:primary_contact_id, account.contacts, current: nil)
                      elsif contacts.blank? && conversation&.contact.present?
                        conversation.contact
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
                 account.crm_pipelines.active.find_by(default: true) || account.crm_pipelines.active.ordered.first
               end

    validation_error!('pipeline_id', 'must reference an active pipeline') if pipeline.blank?

    pipeline.stages.active.find_by(outcome: 'open') || pipeline.stages.active.ordered.first ||
      validation_error!('stage_id', 'must reference an active stage')
  end

  def resolve_title
    title = resolve_optional_text(:title, current: deal.title)
    validation_error!('title', 'is required') if title.blank?

    title
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

  def write_event!(new_record:, contacts_changed:)
    return unless new_record || contacts_changed || filtered_previous_changes.present?

    ::Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: new_record ? 'deal_created' : 'deal_updated',
      meta: {
        changes: filtered_previous_changes,
        contact_ids: deal.deal_contacts.ordered.pluck(:contact_id),
        primary_contact_id: deal.primary_contact_id
      }
    )
  end
end
