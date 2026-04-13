class Outbound::RenderedTextService
  RAW_CODE_REGEX = /`(.*?)`/m.freeze

  attr_reader :content, :conversation, :contact, :inbox, :account, :sender

  def initialize(content:, conversation: nil, contact: nil, inbox: nil, account: nil, sender: nil)
    @content = content.to_s
    @conversation = conversation
    @contact = contact
    @inbox = inbox
    @account = account
    @sender = sender
  end

  def render
    return '' if content.blank?

    text_with_field_values = field_reference_renderer.render(
      protected_liquid_content(content)
    )
    process_liquid_string(text_with_field_values)
  end

  private

  def process_liquid_string(text)
    return text if text.blank?

    template = Liquid::Template.parse(text)
    template.render(message_drops)
  rescue Liquid::Error
    text
  end

  def protected_liquid_content(text)
    text.gsub(RAW_CODE_REGEX, '{% raw %}`\1`{% endraw %}')
  end

  def message_drops
    drops = {
      'contact' => contact_drop,
      'agent' => agent_drop,
      'conversation' => conversation_drop,
      'inbox' => inbox_drop,
      'account' => account_drop
    }

    if defined?(Captain::ContextFields) && resolved_conversation.present?
      drops['deal'] = build_runtime_state_drop(
        Captain::ContextFields.deal_state_for(
          account: resolved_account,
          conversation: resolved_conversation
        )
      )
      drops['task'] = build_runtime_state_drop(
        Captain::ContextFields.task_state_for(
          account: resolved_account,
          conversation: resolved_conversation
        )
      )
      drops['appointment'] = build_runtime_state_drop(
        Captain::ContextFields.appointment_state_for(
          account: resolved_account,
          conversation: resolved_conversation
        )
      )
    end

    drops.compact
  end

  def contact_drop
    ContactDrop.new(resolved_contact) if resolved_contact.present?
  end

  def agent_drop
    UserDrop.new(sender) if sender.present?
  end

  def conversation_drop
    ConversationDrop.new(resolved_conversation) if resolved_conversation.present?
  end

  def inbox_drop
    InboxDrop.new(resolved_inbox) if resolved_inbox.present?
  end

  def account_drop
    AccountDrop.new(resolved_account) if resolved_account.present?
  end

  def build_runtime_state_drop(state)
    return if state.blank?

    RuntimeStateDrop.new(state)
  end

  def field_reference_renderer
    @field_reference_renderer ||= FieldReferences::RendererService.new(
      conversation: resolved_conversation,
      contact: resolved_contact,
      inbox: resolved_inbox,
      account: resolved_account,
      sender: sender
    )
  end

  def resolved_conversation
    conversation
  end

  def resolved_contact
    contact || resolved_conversation&.contact
  end

  def resolved_inbox
    inbox || resolved_conversation&.inbox
  end

  def resolved_account
    account || resolved_conversation&.account || resolved_inbox&.account
  end
end
