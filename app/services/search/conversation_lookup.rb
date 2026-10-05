# Finds the conversations a typed query points at: by the contact (name, e-mail, identifier, a phone number in any
# format), by the conversation number or by the text of a message (literally, see Search::MessageQuery). Used by the
# conversation list search (classic and communication-thread mode) and by the message arm of the global conversation
# search.
#
# SECURITY: the caller passes the conversations the user may OPEN (Conversations::PermissionFilterService). Every id that
# leaves this class is intersected with that scope, whichever source it came from, so neither a contact name, a phone
# number nor the text of a message can lead to a conversation outside it. That matters for a custom role, which can
# open fewer conversations than the inboxes it is a member of: for such a user (restricted: true) the messages are also
# limited to the permitted conversations BEFORE the newest ones are chosen, so that the newest matches are not all in
# conversations he cannot open.
#
# Every source is bounded (the newest matches only), so a search costs the same on a large account as on a small one;
# #capped? says that a bound was reached and there may be more.
class Search::ConversationLookup
  CONTACT_LIMIT = 200
  CONVERSATION_LIMIT = 500
  MESSAGE_LIMIT = 100
  MIN_TEXT_LENGTH = 3
  DISPLAY_ID = /\A#?(\d{1,9})\z/

  def initialize(account:, raw_query:, scope:, inbox_ids: nil, restricted: false, message_since: Search::MessageQuery.lookback_since)
    @account = account
    @text = Search::QueryText.clean(raw_query)
    @scope = scope
    @inbox_ids = inbox_ids
    @restricted = restricted
    @message_since = message_since
    @capped = false
    @partial = false
  end

  # True when a source reached its limit, i.e. there may be older matches that are not returned.
  def capped?
    @capped
  end

  # True when the search of message text was cancelled by its time limit (contacts and numbers are still found).
  def partial?
    @partial
  end

  def display_id
    @display_id ||= @text[DISPLAY_ID, 1]&.to_i
  end

  def searchable?
    display_id.present? || Search::PhoneQuery.parse(@text).present? || text_searchable?
  end

  def conversation_ids
    return [] unless searchable?

    by_contact | message_conversation_ids | by_display_id
  end

  # The conversations whose messages contain the text, newest messages first.
  def message_conversation_ids
    return [] unless text_searchable?

    @message_conversation_ids ||= begin
      result = Search::MessageQuery.new(@text).newest(message_scope, limit: MESSAGE_LIMIT)
      @capped ||= result.rows.size >= MESSAGE_LIMIT
      @partial ||= result.partial
      @scope.where(id: result.rows.map(&:last).uniq).pluck(:id)
    end
  end

  private

  def text_searchable?
    @text.length >= MIN_TEXT_LENGTH
  end

  # The contacts are looked for only when the text is long enough to mean something (3 characters, or a phone number,
  # whose own minimum is 4 digits), so a one- or two-letter query never scans the contacts.
  def by_contact
    return [] unless text_searchable? || Search::PhoneQuery.parse(@text)

    contact_ids = Search::ContactQuery.new(@text).apply(@account.contacts)
                                      .reorder(Contact.arel_table[:last_activity_at].desc.nulls_last).limit(CONTACT_LIMIT).pluck(:id)
    return [] if contact_ids.empty?

    ids = @scope.where(contact_id: contact_ids).reorder(Conversation.arel_table[:last_activity_at].desc).limit(CONVERSATION_LIMIT).pluck(:id)
    @capped ||= contact_ids.size >= CONTACT_LIMIT || ids.size >= CONVERSATION_LIMIT
    ids
  end

  def by_display_id
    return [] if display_id.blank?

    @scope.where(display_id: display_id).pluck(:id)
  end

  def message_scope
    scope = @account.messages.where(
      message_type: [Message.message_types[:incoming], Message.message_types[:outgoing]],
      created_at: @message_since..
    )
    scope = scope.where(inbox_id: @inbox_ids) if @inbox_ids
    scope = scope.where(conversation_id: @scope.select(:id)) if @restricted
    scope
  end
end
