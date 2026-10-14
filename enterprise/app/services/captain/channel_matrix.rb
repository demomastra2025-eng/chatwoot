# frozen_string_literal: true

# Workspace routing editor. The historical agent/channel membership rows stay in
# storage, but only the workspace main agent and each text channel's switch run.
class Captain::ChannelMatrix
  class Invalid < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super(errors.map { |error| error[:message] }.join(', '))
    end
  end

  def initialize(account)
    @account = account
  end

  def payload
    agents = account.captain_assistants.external_agent.order(:id).to_a
    main_id = account.captain_default_assistant_id&.to_i
    links = CaptainInbox.where(inbox_id: text_inboxes.map(&:id)).index_by(&:inbox_id)
    {
      default_main_assistant_id: main_id,
      channels: text_inboxes.map do |inbox|
        link = links[inbox.id]
        { inbox_id: inbox.id, name: inbox.name, channel_type: inbox.channel_type,
          ai_enabled: link&.ai_enabled? || false, main_assistant_id: main_id,
          assistant_ids: agents.select(&:entry_eligible?).map(&:id),
          auto_reply_mode: account.captain_reply_time_mode }
      end,
      assistants: agents.map do |agent|
        { id: agent.id, name: agent.name, avatar_url: agent.avatar_url,
          routing_description: agent.routing_description, active: agent.active?,
          channel_scope: 'all', inbox_ids: [] }
      end
    }
  end

  def update!(input)
    data = input.respond_to?(:to_unsafe_h) ? input.to_unsafe_h : input.to_h
    data = data.deep_stringify_keys
    account.with_lock do
      update_main!(data['default_main_assistant_id']) if data.key?('default_main_assistant_id')
      update_channels!(data['channels']) if data.key?('channels')
    end
    payload
  end

  private

  attr_reader :account

  def text_inboxes
    @text_inboxes ||= account.inboxes.where.not(channel_type: 'Channel::Voice').order(:id).to_a
  end

  def update_main!(value)
    id = Integer(value, exception: false)
    assistant = account.captain_assistants.entry_eligible.find_by(id: id)
    invalid!('INVALID_DEFAULT') unless assistant

    account.update!(captain_default_assistant_id: assistant.id)
    text_inboxes.each do |inbox|
      link = CaptainInbox.find_by(inbox_id: inbox.id)
      if link
        link.update!(captain_assistant: assistant) if link.captain_assistant_id != assistant.id
      else
        CaptainInbox.create!(inbox: inbox, captain_assistant: assistant, ai_enabled: false)
      end
    end
  end

  def update_channels!(rows)
    invalid!('INVALID_CHANNEL') unless rows.is_a?(Array)

    rows.each { |row| update_channel!(row) }
  end

  def update_channel!(row)
    invalid!('INVALID_CHANNEL') unless row.is_a?(Hash)
    row = row.stringify_keys
    id = Integer(row['inbox_id'], exception: false)
    inbox = text_inboxes.find { |item| item.id == id }
    invalid!('INVALID_CHANNEL', inbox_id: id) unless inbox
    return unless row.key?('ai_enabled')

    enabled = row['ai_enabled']
    invalid!('INVALID_AI_ENABLED', inbox_id: id) unless [true, false].include?(enabled)
    save_channel_switch!(inbox, enabled)
  end

  def save_channel_switch!(inbox, enabled)
    link = CaptainInbox.find_by(inbox_id: inbox.id)
    return link.update!(ai_enabled: enabled) if link
    return unless enabled

    main = account.captain_assistants.entry_eligible.find_by(id: account.captain_default_assistant_id)
    invalid!('MAIN_AGENT_REQUIRED', inbox_id: inbox.id) unless main
    CaptainInbox.create!(inbox: inbox, captain_assistant: main, ai_enabled: true)
  end

  def invalid!(code, inbox_id: nil)
    raise Invalid, [{ inbox_id: inbox_id, assistant_id: nil, code: code,
                      message: I18n.t("captain.channel_matrix.#{code.downcase}") }]
  end
end
