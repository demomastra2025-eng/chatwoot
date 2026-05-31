class Linear::ActivityMessageService
  ACTIVITY_LOCALE = :en

  attr_reader :conversation, :action_type, :issue_data, :user

  def initialize(conversation:, action_type:, user:, issue_data: {})
    @conversation = conversation
    @action_type = action_type
    @issue_data = issue_data
    @user = user
  end

  def perform
    return unless conversation && issue_data[:id] && user

    content = generate_activity_content
    return unless content

    ::Conversations::ActivityMessageJob.perform_later(conversation, activity_message_params(content))
  end

  private

  def generate_activity_content
    case action_type.to_sym
    when :issue_created
      activity_text('conversations.activity.linear.issue_created')
    when :issue_linked
      activity_text('conversations.activity.linear.issue_linked')
    when :issue_unlinked
      activity_text('conversations.activity.linear.issue_unlinked')
    end
  end

  def activity_text(key)
    I18n.t(key, locale: ACTIVITY_LOCALE, user_name: user.name, issue_id: issue_data[:id])
  end

  def activity_message_params(content)
    {
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content: content
    }
  end
end
