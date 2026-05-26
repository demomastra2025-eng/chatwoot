class Public::Api::V1::InboxesController < PublicController
  before_action :set_inbox_channel
  before_action :set_contact_inbox
  before_action :set_conversation

  def show
    @inbox_channel = find_inbox_channel!(params[:id])
  end

  private

  def set_inbox_channel
    return if params[:inbox_id].blank?

    @inbox_channel = find_inbox_channel!(params[:inbox_id])
  end

  def set_contact_inbox
    return if params[:contact_id].blank?

    @contact_inbox = @inbox_channel.inbox.contact_inboxes.find_by!(source_id: params[:contact_id])
  end

  def set_conversation
    return if params[:conversation_id].blank?

    @conversation = if @contact_inbox.hmac_verified?
                      @contact_inbox.contact.conversations.find_by!(display_id: params[:conversation_id])
                    else
                      @contact_inbox.conversations.find_by!(display_id: params[:conversation_id])
                    end
  end

  def find_inbox_channel!(identifier)
    Inbox
      .joins("INNER JOIN #{Channel::Api.table_name} ON #{Channel::Api.table_name}.id = inboxes.channel_id")
      .where(channel_type: Inbox::API_CHANNEL_TYPES)
      .where(channel_api: { identifier: identifier })
      .first!
      .channel
  end
end
