class Crm::Deals::AutoCreateFromChannelContactService
  AUTO_IDEMPOTENCY_KEY_PREFIX = 'auto_channel_contact'.freeze

  pattr_initialize [:contact_inbox!, { conversation: nil, message: nil }]

  def perform
    return [] unless account.feature_enabled?('crm_deals')
    return [] if contact.blank? || contact.account_id != account.id
    return [] if conversation && (conversation.account_id != account.id || conversation.contact_id != contact.id)
    return [] if message.present? && (!message.incoming? || message.private? || message.account_id != account.id || message.conversation_id != conversation&.id)

    contact.with_lock do
      auto_create_pipelines.filter_map do |pipeline|
        create_deal_for_pipeline(pipeline)
      end
    end
  end

  private

  def account
    @account ||= contact_inbox.inbox.account
  end

  def contact
    @contact ||= contact_inbox.contact
  end

  def auto_create_pipelines
    account.crm_pipelines.active.where(auto_create_deal_on_channel_contact: true).ordered
  end

  def create_deal_for_pipeline(pipeline)
    return if processed_event?(pipeline)

    ApplicationRecord.transaction(requires_new: true) do
      deal = create_when_no_active_deal(pipeline)
      record_processed_event!(pipeline)
      deal
    end
  rescue ActiveRecord::RecordNotUnique
    raise unless account.crm_deals.exists?(idempotency_key: idempotency_key_for(pipeline))

    nil
  rescue ActiveRecord::RecordInvalid
    nil
  rescue ::Crm::Error => e
    # Inbound delivery has already committed. A required field can skip CRM creation; logs carry only codes and ids.
    log_skipped_deal(pipeline, e)
    nil
  end

  def create_when_no_active_deal(pipeline)
    return if existing_deal_for_pipeline?(pipeline)
    return if superseded_message?(pipeline)

    stage = default_stage_for(pipeline)
    return if stage.blank?

    ::Crm::Deals::UpsertService.new(account: account, params: deal_params(pipeline: pipeline, stage: stage), actor: nil).perform
  end

  def processed_event?(pipeline)
    return false if message.blank?

    account.crm_events.exists?(eventable: contact, event_type: 'channel_contact_checked', command_key: idempotency_key_for(pipeline))
  end

  def record_processed_event!(pipeline)
    return if message.blank?

    Crm::Events::Writer.record!(
      account: account, eventable: contact, actor: nil, event_type: 'channel_contact_checked',
      command_key: idempotency_key_for(pipeline), meta: { pipeline_id: pipeline.id, message_id: message.id }
    )
  end

  def log_skipped_deal(pipeline, error)
    Rails.logger.warn(
      "Crm auto-create deal skipped: account_id=#{account.id} pipeline_id=#{pipeline.id} " \
      "error=#{error.class.name} code=#{error.code}"
    )
  end

  def existing_deal_for_pipeline?(pipeline)
    account.crm_deals
           .kept
           .where(closed_at: nil)
           .joins(:deal_contacts, :stage)
           .where(pipeline_id: pipeline.id)
           .exists?(crm_deal_contacts: { contact_id: contact.id, primary: true }, crm_stages: { outcome: 'open' })
  end

  def superseded_message?(pipeline)
    return false if message.blank?

    account.crm_deals.joins(:deal_contacts).where(pipeline_id: pipeline.id)
           .where(crm_deal_contacts: { contact_id: contact.id, primary: true })
           .where('crm_deals.closed_at >= :event_at OR crm_deals.archived_at >= :event_at', event_at: message.created_at).exists?
  end

  def default_stage_for(pipeline)
    pipeline.stages.active.where(outcome: 'open').find_by(default: true) ||
      pipeline.stages.active.where(outcome: 'open').ordered.first
  end

  def deal_params(pipeline:, stage:)
    params = {
      pipeline_id: pipeline.id,
      stage_id: stage.id,
      contact_ids: [contact.id],
      primary_contact_id: contact.id,
      title: deal_title,
      idempotency_key: idempotency_key_for(pipeline)
    }
    params[:originating_conversation_id] = conversation.id if conversation.present?
    params
  end

  def deal_title
    contact.name.presence || contact.email.presence || contact.phone_number.presence || "Contact ##{contact.id}"
  end

  def idempotency_key_for(pipeline)
    return "#{AUTO_IDEMPOTENCY_KEY_PREFIX}:pipeline:#{pipeline.id}:message:#{message.id}" if message.present?

    @invocation_key ||= SecureRandom.uuid
    "#{AUTO_IDEMPOTENCY_KEY_PREFIX}:pipeline:#{pipeline.id}:invocation:#{@invocation_key}"
  end
end
