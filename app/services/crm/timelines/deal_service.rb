class Crm::Timelines::DealService < Crm::Timelines::BaseService
  def initialize(account:, deal:, actor:, params: {})
    @deal = deal
    super(account: account, actor: actor, params: params)
  end

  def perform
    timeline_response(event_items + comment_items + conversation_items)
  end

  private

  attr_reader :deal

  def comment_items
    scope = deal.comments.kept.includes(:user).ordered
    scope = scope.where('crm_comments.created_at < ?', before_time) if before_time.present?

    scope.limit(limit).map do |comment|
      {
        item_type: 'comment',
        occurred_at: comment.created_at,
        sort_id: comment.id,
        payload: ::Crm::PayloadBuilder.comment(comment)
      }
    end
  end

  def conversation_items
    filtered_conversations.limit(limit).map do |conversation|
      {
        item_type: 'conversation',
        occurred_at: conversation.last_activity_at,
        sort_id: conversation.id,
        payload: ::Crm::PayloadBuilder.compact_conversation(conversation)
      }
    end
  end

  def event_items
    scope = deal.events.includes(:actor).order(created_at: :desc, id: :desc)
    scope = scope.where('crm_events.created_at < ?', before_time) if before_time.present?

    scope.limit(limit).map do |event|
      {
        item_type: 'event',
        occurred_at: event.created_at,
        sort_id: event.id,
        payload: ::Crm::PayloadBuilder.event(event)
      }
    end
  end

  def filtered_conversations
    scope = ::Conversations::PermissionFilterService.new(related_conversations, actor, account).perform
    scope = scope.where('conversations.last_activity_at < ?', before_time) if before_time.present?

    scope.includes(:contact).order(last_activity_at: :desc, id: :desc).distinct
  end

  def related_conversations
    contact_scope = account.conversations.where(contact_id: deal.deal_contacts.select(:contact_id))
    return contact_scope if deal.originating_conversation_id.blank?

    contact_scope.or(account.conversations.where(id: deal.originating_conversation_id))
  end
end
