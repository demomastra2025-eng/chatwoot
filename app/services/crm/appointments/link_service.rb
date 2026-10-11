class Crm::Appointments::LinkService
  RESULT_ATTRIBUTE = 'crm_link_result'.freeze
  OPTIONAL_SELECTION_ERRORS = %w[CRM_DEAL_SELECTION_REQUIRED CRM_PIPELINE_NO_OPEN_STAGE].freeze

  def initialize(appointment:, params: {}, actor: nil, newly_imported: false)
    @appointment = appointment
    @params = params.to_h.deep_symbolize_keys
    @actor = actor
    @newly_imported = newly_imported
  end

  def perform
    return appointment.crm_deal if appointment.crm_deal_id.present?
    return unless appointment.new_record? || newly_imported
    return unless account.feature_enabled?('crm_deals')
    return unless appointment.contact && appointment.contact.account_id == account.id

    appointment.contact.with_lock { link_with_savepoint }
  end

  private

  attr_reader :appointment, :params, :actor, :newly_imported

  def account
    appointment.account
  end

  def link_with_savepoint
    # A CRM validation failure rolls back its own deal/contact/event writes,
    # while leaving the surrounding appointment transaction usable.
    ApplicationRecord.transaction(requires_new: true) { resolve_and_link! }
  rescue Crm::Error, ActiveRecord::RecordInvalid => e
    record_unlinked_result!(e)
  rescue Scheduling::Error => e
    raise unless e.code.in?(OPTIONAL_SELECTION_ERRORS)

    record_unlinked_result!(e)
  end

  def resolve_and_link!
    deal = if params[:crm_deal_id].present?
             explicit_deal!
           elsif params[:crm_deal_selection] == 'create'
             create_deal!(account.crm_pipelines.active.find(params[:crm_pipeline_id]))
           elsif params[:crm_pipeline_id].present?
             explicit_pipeline_deal
           elsif newly_imported || appointment.conversation.blank?
             direct_source_deal
           else
             dialog_deal
           end
    return unless deal

    deal.with_lock do
      config = Crm::Appointments::Configuration.for(deal.pipeline)
      if config['auto_create_deals'] == true && config['cardinality'] == 'appointment' && deal.appointments.exists?
        deal = create_deal!(deal.pipeline, source_deal: deal)
      end
      appointment.crm_deal = deal
      appointment.custom_attributes = appointment.custom_attributes.to_h.except(RESULT_ATTRIBUTE)
    end
    deal
  end

  def explicit_deal!
    deal = candidates.find_by(id: params[:crm_deal_id])
    return deal if deal

    raise Scheduling::Error.new(code: 'CRM_DEAL_CONTACT_MISMATCH', message: 'Select an active deal for the communication contact', status: :unprocessable_content)
  end

  def candidates
    Crm::Appointments::CandidateScope.resolve(account: account, contact: appointment.contact, pipeline_id: params[:crm_pipeline_id])
  end

  def explicit_pipeline_deal
    pipeline = account.crm_pipelines.active.find(params[:crm_pipeline_id])
    matches = candidates.order(:id).limit(2).to_a
    return matches.first if matches.one?
    require_selection! if matches.many?

    create_deal!(pipeline) if Crm::Appointments::Configuration.for(pipeline)['auto_create_deals'] == true
  end

  def dialog_deal
    matches = candidates.order(:id).limit(2).to_a
    return matches.first if matches.one?
    require_selection! if matches.many?

    direct_source_deal
  end

  def direct_source_deal
    key = newly_imported ? 'auto_create_from_medelement' : 'auto_create_from_calendar'
    pipeline = account.crm_pipelines.active.where("appointment_automation ->> ? = 'true'", key).ordered.detect do |candidate|
      Crm::Appointments::Configuration.for(candidate)['auto_create_deals'] == true
    end
    return unless pipeline && prospective?(pipeline, key)

    scope = Crm::Appointments::CandidateScope.resolve(account: account, contact: appointment.contact, pipeline_id: pipeline.id)
    matches = scope.order(:id).limit(2).to_a
    return create_deal!(pipeline) if Crm::Appointments::Configuration.for(pipeline)['cardinality'] == 'appointment' || matches.empty?
    return matches.first if matches.one?

    # A provider import has no interactive chooser. Keep the new reception separate when requests are ambiguous.
    newly_imported ? create_deal!(pipeline) : require_selection!
  end

  def prospective?(pipeline, key)
    enabled_at = Time.iso8601(pipeline.appointment_automation.fetch("#{key}_enabled_at"))
    return true unless newly_imported

    source_created = Crm::Appointments::SourceCreationTime.for(appointment)
    source_created.present? && source_created >= enabled_at && appointment.created_at >= enabled_at
  rescue ArgumentError, KeyError
    false
  end

  def create_deal!(pipeline, source_deal: nil)
    stage = pipeline.stages.active.where(outcome: 'open').find_by(default: true) || pipeline.stages.active.where(outcome: 'open').ordered.first
    unless stage
      raise Scheduling::Error.new(code: 'CRM_PIPELINE_NO_OPEN_STAGE', message: 'Select a pipeline with an active open stage', status: :unprocessable_content)
    end

    key = "appointment_deal:#{appointment.id || appointment.idempotency_key.presence || SecureRandom.uuid}:pipeline:#{pipeline.id}"
    existing = account.crm_deals.find_by(idempotency_key: key)
    return existing if existing

    Crm::Deals::UpsertService.new(
      account: account, actor: actor.is_a?(User) ? actor : nil,
      params: {
        pipeline_id: pipeline.id, stage_id: stage.id, title: source_deal&.title.presence || appointment.contact.name.presence || appointment.client_name,
        contact_ids: [appointment.contact_id, appointment.patient_contact_id].compact.uniq, primary_contact_id: appointment.contact_id,
        originating_conversation_id: appointment.conversation_id || source_deal&.originating_conversation_id,
        originating_communication_thread_id: source_deal&.originating_communication_thread_id,
        idempotency_key: key
      }
    ).perform
  end

  def require_selection!
    raise Scheduling::Error.new(
      code: 'CRM_DEAL_SELECTION_REQUIRED', message: 'Choose a deal or create a new deal for this appointment', status: :unprocessable_content
    )
  end

  def record_unlinked_result!(error)
    code = error.respond_to?(:code) ? error.code : 'CRM_DEAL_VALIDATION_ERROR'
    details = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.to_hash : error.details
    appointment.custom_attributes = appointment.custom_attributes.to_h.merge(
      RESULT_ATTRIBUTE => {
        'status' => 'not_linked', 'code' => code,
        'message' => 'The appointment was saved without a CRM deal. Review the deal requirements or select an existing deal.',
        'details' => details
      }.compact
    )
    Rails.logger.info("Appointment CRM link skipped: account_id=#{account.id} appointment_id=#{appointment.id} code=#{code}")
    nil
  end
end
