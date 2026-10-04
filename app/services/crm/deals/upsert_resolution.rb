module Crm::Deals::UpsertResolution
  private

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
    contacts = requested_contacts
    primary_contact = resolve_primary_contact(
      contacts: contacts,
      source_contact: communication_thread&.contact || conversation&.contact
    )
    [contacts | [primary_contact].compact, primary_contact]
  end

  def requested_contacts
    return resolve_many_records(account.contacts, params[:contact_ids]) if params.key?(:contact_ids)

    deal.contacts.to_a
  end

  def resolve_primary_contact(contacts:, source_contact:)
    return resolve_optional_record(:primary_contact_id, account.contacts, current: nil) if params.key?(:primary_contact_id)
    return source_contact if contacts.blank? && source_contact.present?

    deal.deal_contacts.find(&:primary?)&.contact || contacts.first
  end

  def resolve_stage!
    return account.crm_stages.find(params[:stage_id]) if requested_stage_id?
    return deal.stage if deal.persisted?

    pipeline = resolve_pipeline
    validation_error!('pipeline_id', 'must reference an active pipeline') if pipeline.blank?
    default_stage_for(pipeline) || validation_error!('stage_id', 'must reference an active stage')
  end

  def requested_stage_id?
    params.key?(:stage_id) && params[:stage_id].present?
  end

  def resolve_pipeline
    return account.crm_pipelines.find(params[:pipeline_id]) if requested_pipeline_id?

    account.crm_pipelines.active.find_by(default: true) || account.crm_pipelines.active.ordered.first
  end

  def requested_pipeline_id?
    params.key?(:pipeline_id) && params[:pipeline_id].present?
  end

  def default_stage_for(pipeline)
    stages = pipeline.stages.active
    stages.find_by(default: true) || stages.find_by(outcome: 'open') || stages.ordered.first
  end

  def resolve_title
    title = resolve_optional_text(:title, current: deal.title)
    validation_error!('title', 'is required') if title.blank?
    title
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
end
