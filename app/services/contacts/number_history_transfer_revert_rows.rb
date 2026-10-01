# Returns the rows tied to reverted chats (calls, call sessions, CSAT answers, ad referrals, lead submissions) to the
# previous holder, like their messages: every such row of the reverted conversations (lead submissions also by the
# reverted ContactInboxes) that still belongs to the recipient, including rows it got there after the transfer, because
# the whole chat goes back. The transfer records the ids it moved per table ('conversation_rows') for tracing; rows of a
# chat that is not reverted (its ContactInbox no longer belongs to the recipient) stay.
class Contacts::NumberHistoryTransferRevertRows
  TABLES = Contacts::NumberHistoryTransferService::CONVERSATION_TABLES

  def self.refresh_referral_threads!(conversation_ids)
    connection = ActiveRecord::Base.connection
    return if conversation_ids.empty? || !connection.data_source_exists?('meta_ad_referrals')

    CommunicationThreadConversation.where(conversation_id: conversation_ids).pluck(:conversation_id, :communication_thread_id)
                                   .each do |conversation_id, thread_id|
      connection.update("UPDATE meta_ad_referrals SET communication_thread_id = #{thread_id.to_i} WHERE conversation_id = #{conversation_id.to_i}")
    end
  end

  def initialize(from:, to:, contact_inbox_ids:, conversation_ids:)
    @from = from
    @to = to
    @contact_inbox_ids = contact_inbox_ids
    @conversation_ids = conversation_ids
  end

  # Returns { table => ids moved back }.
  def perform
    TABLES.each_with_object({}) do |table, moved|
      next unless connection.data_source_exists?(table)

      # Back from the recipient to the previous holder: the transfer's SQL with the contacts swapped.
      ids = connection.select_values(
        Contacts::NumberHistoryTransferService.conversation_rows_update_sql(
          table, from_id: @to.id, to_id: @from.id, conversation_ids: @conversation_ids, contact_inbox_ids: @contact_inbox_ids
        )
      )
      moved[table] = ids.map(&:to_i).sort if ids.any?
    end
  end

  private

  def connection = ActiveRecord::Base.connection
end
