class AgentNotifications::ConversationNotificationsMailer < ApplicationMailer
  def conversation_creation(conversation, agent, _user)
    return unless smtp_config_set_or_development?

    @agent = agent
    @conversation = conversation
    inbox_name = @conversation.inbox&.sanitized_name
    subject = "#{@agent.available_name}, A new conversation [ID - #{@conversation.display_id}] has been created in #{inbox_name}."
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    send_mail_with_liquid(to: @agent.email, subject: subject) and return
  end

  def conversation_assignment(conversation, agent, _user)
    return unless smtp_config_set_or_development?

    @agent = agent
    @conversation = conversation
    subject = "#{@agent.available_name}, A new conversation [ID - #{@conversation.display_id}] has been assigned to you."
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    send_mail_with_liquid(to: @agent.email, subject: subject) and return
  end

  def conversation_mention(conversation, agent, message)
    return unless smtp_config_set_or_development?

    @agent = agent
    @conversation = conversation
    @message = message
    subject = "#{@agent.available_name}, You have been mentioned in conversation [ID - #{@conversation.display_id}]"
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    send_mail_with_liquid(to: @agent.email, subject: subject) and return
  end

  def assigned_conversation_new_message(conversation, agent, message)
    return unless smtp_config_set_or_development?
    # Don't spam with email notifications if agent is online
    return if ::OnlineStatusTracker.get_presence(message.account_id, 'User', agent.id)

    @agent = agent
    @conversation = conversation
    subject = "#{@agent.available_name}, New message in your assigned conversation [ID - #{@conversation.display_id}]."
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    send_mail_with_liquid(to: @agent.email, subject: subject) and return
  end

  def participating_conversation_new_message(conversation, agent, message)
    return unless smtp_config_set_or_development?
    # Don't spam with email notifications if agent is online
    return if ::OnlineStatusTracker.get_presence(message.account_id, 'User', agent.id)

    @agent = agent
    @conversation = conversation
    subject = "#{@agent.available_name}, New message in your participating conversation [ID - #{@conversation.display_id}]."
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    send_mail_with_liquid(to: @agent.email, subject: subject) and return
  end

  def task_assignment(task, agent, actor = nil)
    assignment_notification(
      record: task,
      agent: agent,
      actor: actor,
      label: 'task',
      path: "/app/accounts/#{task.account_id}/crm/tasks?taskId=#{task.id}"
    )
  end

  def appointment_assignment(appointment, agent, actor = nil)
    assignment_notification(
      record: appointment,
      agent: agent,
      actor: actor,
      label: 'appointment',
      path: "/app/accounts/#{appointment.account_id}/scheduling/calendar?appointmentId=#{appointment.id}"
    )
  end

  def deal_assignment(deal, agent, actor = nil)
    assignment_notification(
      record: deal,
      agent: agent,
      actor: actor,
      label: 'deal',
      path: "/app/accounts/#{deal.account_id}/crm/deals?dealId=#{deal.id}"
    )
  end

  private

  def assignment_notification(record:, agent:, actor:, label:, path:)
    return unless smtp_config_set_or_development?

    @agent = agent
    @record = record
    @actor = actor
    @assignment_label = label
    @action_url = frontend_url(path)
    subject = "#{@agent.available_name}, a #{label} [ID - #{record.id}] has been assigned to you."
    send_mail_with_liquid(to: @agent.email, subject: subject) and return
  end

  def frontend_url(path)
    base_url = ENV.fetch('FRONTEND_URL', nil).presence || ENV.fetch('INSTALLATION_URL', nil).presence
    return path if base_url.blank?

    "#{base_url}#{path}"
  end

  def liquid_droppables
    super.merge({
                  user: @agent,
                  conversation: @conversation,
                  inbox: @conversation&.inbox,
                  message: @message,
                  record: @record,
                  actor: @actor,
                  assignment_label: @assignment_label
                })
  end
end

AgentNotifications::ConversationNotificationsMailer.prepend_mod_with('AgentNotifications::ConversationNotificationsMailer')
