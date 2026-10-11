class BaseListener
  include Singleton

  def extract_conversation_and_account(event)
    conversation = event.data[:conversation]
    [conversation, conversation.account]
  end

  def extract_notification_and_account(event)
    notification = event.data[:notification]
    notification_finder = NotificationFinder.new(notification.user, notification.account)
    unread_count = notification_finder.unread_count
    count = notification_finder.count
    [notification, notification.account, unread_count, count]
  end

  def extract_message_and_account(event)
    message = event.data[:message]
    [message, message.account]
  end

  def extract_contact_and_account(event)
    contact = event.data[:contact]
    [contact, contact.account]
  end

  def extract_appointment_and_account(event)
    appointment = event.data[:appointment]
    [appointment, appointment.account]
  end

  def extract_deal_and_account(event)
    deal = event.data[:deal]
    [deal, deal.account]
  end

  def extract_task_and_account(event)
    task = event.data[:task]
    [task, task.account]
  end

  def extract_inbox_and_account(event)
    inbox = event.data[:inbox]
    [inbox, inbox.account]
  end

  def extract_changed_attributes(event)
    changed_attributes = event.data[:changed_attributes]

    return if changed_attributes.blank?

    changed_attributes.map do |key, values|
      previous_value, current_value = values
      if key.to_s == 'additional_attributes'
        previous_value = Conversations::EventDataPresenter.external_additional_attributes(previous_value)
        current_value = Conversations::EventDataPresenter.external_additional_attributes(current_value)
      end
      { key => { previous_value: previous_value, current_value: current_value } }
    end
  end
end
