# frozen_string_literal: true

# Workspace routing editor: which text channels the AI answers by itself. Every agent is a peer with its own on/off switch (the agents
# page); a channel names no agent, because the router picks the agent among the enabled ones for each message.
class Captain::ChannelMatrix
  class Invalid < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super(errors.pluck(:message).join(', '))
    end
  end

  def initialize(account)
    @account = account
  end

  def payload
    {
      channels: channel_rows,
      assistants: assistant_rows
    }
  end

  def update!(input)
    data = input.respond_to?(:to_unsafe_h) ? input.to_unsafe_h : input.to_h
    data = data.deep_stringify_keys
    account.with_lock do
      update_channels!(data['channels']) if data.key?('channels')
    end
    payload
  end

  private

  attr_reader :account

  def text_inboxes
    @text_inboxes ||= account.inboxes.where.not(channel_type: CaptainInbox::VOICE_CHANNEL_TYPE).order(:id).to_a
  end

  def channel_rows
    links = CaptainInbox.where(inbox_id: text_inboxes.map(&:id)).index_by(&:inbox_id)
    text_inboxes.map do |inbox|
      { inbox_id: inbox.id, name: inbox.name, channel_type: inbox.channel_type,
        ai_enabled: links[inbox.id]&.ai_enabled? || false, auto_reply_mode: account.captain_reply_time_mode }
    end
  end

  # has_card: the agent has a «what the agent does» description, which the router chooses by.
  def assistant_rows
    account.captain_assistants.external_agent.order(:id).map do |agent|
      { id: agent.id, name: agent.name, avatar_url: agent.avatar_url, active: agent.active?,
        has_card: agent.routing_description.to_s.strip.present? }
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

  # A channel with no row has its auto reply off; switching it on creates the row, which holds the channel settings only.
  def save_channel_switch!(inbox, enabled)
    link = CaptainInbox.find_by(inbox_id: inbox.id)
    return link.update!(ai_enabled: enabled) if link
    return unless enabled

    CaptainInbox.create!(inbox: inbox, ai_enabled: true)
  end

  def invalid!(code, inbox_id: nil)
    raise Invalid, [{ inbox_id: inbox_id, assistant_id: nil, code: code,
                      message: I18n.t("captain.channel_matrix.#{code.downcase}") }]
  end
end
