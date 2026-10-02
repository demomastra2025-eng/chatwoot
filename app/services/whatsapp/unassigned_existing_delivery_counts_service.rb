class Whatsapp::UnassignedExistingDeliveryCountsService
  def initialize(account:, channels:, period:)
    @account = account
    @channels = channels
    @period = period
  end

  def perform
    @channels.each_with_object({}) do |channel, counts|
      inbox = channel.inbox
      next if inbox.blank?

      phone_number = WhatsappUsageDelivery.canonical_phone_number(channel.phone_number)
      unassigned_count = unassigned_message_count(inbox, phone_number)
      counts[phone_number] = unassigned_count if unassigned_count.positive?
    end
  end

  private

  def unassigned_message_count(inbox, phone_number)
    messages = messages_without_delivery(inbox).where(<<~SQL.squish, @account.id, phone_number)
      NOT EXISTS (
        SELECT 1
        FROM whatsapp_usage_deliveries
        WHERE whatsapp_usage_deliveries.account_id = ?
          AND whatsapp_usage_deliveries.phone_number = ?
          AND whatsapp_usage_deliveries.provider_message_id = messages.source_id
      )
    SQL
    messages.reorder(nil).distinct.count(:source_id)
  end

  def messages_without_delivery(inbox)
    Message.without_imported_history.where(
      account_id: @account.id,
      inbox_id: inbox.id,
      created_at: @period,
      message_type: [Message.message_types[:outgoing], Message.message_types[:template]],
      status: Message.statuses.values_at('delivered', 'read'),
      private: false
    ).where.not(source_id: [nil, ''])
           .where(<<~'SQL'.squish)
             NOT CASE json_typeof(messages.content_attributes)
             WHEN 'object' THEN
               LOWER(COALESCE(messages.content_attributes ->> 'external_echo', 'false')) = 'true'
               OR LOWER(COALESCE(messages.content_attributes ->> 'whatsapp_history_import', 'false')) = 'true'
             WHEN 'string' THEN
               COALESCE(messages.content_attributes #>> '{}', '') ~*
                 '"(external_echo|whatsapp_history_import)"\s*:\s*(true|"true")'
             ELSE false
             END
           SQL
  end
end
