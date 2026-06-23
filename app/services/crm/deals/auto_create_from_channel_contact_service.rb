class Crm::Deals::AutoCreateFromChannelContactService
  AUTO_IDEMPOTENCY_KEY_PREFIX = 'auto_channel_contact'.freeze

  pattr_initialize [:contact_inbox!, { conversation: nil }]

  def perform
    return [] unless account.feature_enabled?('crm_deals')
    return [] if contact.blank?

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
    return if existing_deal_for_pipeline?(pipeline)

    stage = default_stage_for(pipeline)
    return if stage.blank?

    ::Crm::Deals::UpsertService.new(
      account: account,
      params: deal_params(pipeline: pipeline, stage: stage),
      actor: nil
    ).perform
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    nil
  end

  def existing_deal_for_pipeline?(pipeline)
    account.crm_deals
           .kept
           .joins(:deal_contacts)
           .where(pipeline_id: pipeline.id)
           .exists?(crm_deal_contacts: { contact_id: contact.id })
  end

  def default_stage_for(pipeline)
    pipeline.stages.active.find_by(default: true) ||
      pipeline.stages.active.find_by(outcome: 'open') ||
      pipeline.stages.active.ordered.first
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
    return "#{AUTO_IDEMPOTENCY_KEY_PREFIX}:pipeline:#{pipeline.id}:conversation:#{conversation.id}" if conversation.present?

    "#{AUTO_IDEMPOTENCY_KEY_PREFIX}:pipeline:#{pipeline.id}:contact:#{contact.id}"
  end
end
