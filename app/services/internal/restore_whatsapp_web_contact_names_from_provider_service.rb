class Internal::RestoreWhatsappWebContactNamesFromProviderService
  DEFAULT_BATCH_SIZE = 100

  pattr_initialize [:account, :inbox, { batch_size: DEFAULT_BATCH_SIZE }]

  def perform
    {
      channels_processed: 0,
      contacts_touched: 0,
      errors: []
    }.tap do |summary|
      target_channels.find_each do |channel|
        summary[:channels_processed] += 1
        summary[:contacts_touched] += restore_channel(channel)
      rescue StandardError => e
        summary[:errors] << {
          channel_id: channel.id,
          inbox_id: channel.inbox_id,
          error_class: e.class.name,
          error_message: e.message
        }
      end
    end
  end

  private

  def target_channels
    scope = Channel::WhatsappWeb.includes(:inbox).order(:id)
    scope = scope.where(account_id: account.id) if account.present?
    scope = scope.where(inbox_id: inbox.id) if inbox.present?
    scope
  end

  def restore_channel(channel)
    touched_contact_ids = {}
    page = 1

    loop do
      records = Array.wrap(channel.provider_service.fetch_contacts(page: page, offset: batch_size))
      break if records.blank?

      records.each do |record|
        contact_inbox = WhatsappWeb::ContactSyncService.new(
          channel: channel,
          contact_payload: record.to_h.deep_symbolize_keys
        ).perform
        touched_contact_ids[contact_inbox.contact_id] = true if contact_inbox.present?
      end

      break if records.size < batch_size

      page += 1
    end

    touched_contact_ids.size
  end
end
