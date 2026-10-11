# frozen_string_literal: true

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
    assistants = external_assistants
    {
      default_main_assistant_id: parse_id(account.captain_default_assistant_id),
      channels: text_inboxes.map do |inbox|
        link = links_by_inbox[inbox.id]
        {
          inbox_id: inbox.id, name: inbox.name, channel_type: inbox.channel_type,
          ai_enabled: link&.ai_enabled? || false, main_assistant_id: link&.captain_assistant_id,
          assistant_ids: assistants.select { |agent| agent.works_on_inbox?(inbox) }.map(&:id),
          auto_reply_mode: link&.auto_reply_mode || CaptainInbox::DEFAULT_AUTO_REPLY_MODE
        }
      end,
      assistants: assistants.map do |agent|
        {
          id: agent.id, name: agent.name, avatar_url: agent.avatar_url,
          routing_description: agent.routing_description, active: agent.active?,
          channel_scope: agent.channel_scope, inbox_ids: agent.channel_scope == 'all' ? [] : agent.selected_inbox_ids
        }
      end
    }
  end

  def update!(input)
    account.with_lock do
      load_state
      stage(input)
      validate_state
      raise Invalid, @errors if @errors.any?

      save_state
    end
    @links_by_inbox = nil
    payload
  end

  private

  attr_reader :account

  def external_assistants
    @external_assistants ||= account.captain_assistants.external_agent.order(:id).to_a
  end

  def text_inboxes
    @text_inboxes ||= account.inboxes.where.not(channel_type: 'Channel::Voice').order(:id).to_a
  end

  def links_by_inbox
    @links_by_inbox ||= CaptainInbox.where(inbox_id: text_inboxes.map(&:id)).order(id: :desc).index_by(&:inbox_id)
  end

  def load_state
    @errors = []
    duplicate_ids = CaptainInbox.where(inbox_id: text_inboxes.map(&:id)).group(:inbox_id).having('COUNT(*) > 1').count.keys
    duplicate_ids.each { |id| add_error('DUPLICATE_INBOX', inbox_id: id) }
    @agents = external_assistants.index_by(&:id)
    @inboxes = text_inboxes.index_by(&:id)
    @assistant_state = @agents.transform_values { |agent| { scope: agent.channel_scope, inbox_ids: agent.selected_inbox_ids } }
    @channel_state = @inboxes.transform_values do |inbox|
      link = links_by_inbox[inbox.id]
      { link: link, ai_enabled: link&.ai_enabled? || false, main_id: link&.captain_assistant_id,
        auto_reply_mode: link&.auto_reply_mode || CaptainInbox::DEFAULT_AUTO_REPLY_MODE }
    end
    @default_id = parse_id(account.captain_default_assistant_id)
  end

  def stage(input)
    data = input.respond_to?(:to_unsafe_h) ? input.to_unsafe_h : input.to_h
    stage_default(data) if data.key?('default_main_assistant_id')
    stage_assistants(data['assistants']) if data.key?('assistants')
    stage_channels(data['channels']) if data.key?('channels')
  end

  def stage_default(data)
    value = data['default_main_assistant_id']
    @default_id = value.nil? ? nil : parse_id(value)
    add_error('INVALID_DEFAULT') if !value.nil? && @default_id.nil?
  end

  def stage_assistants(rows)
    return add_error('INVALID_ASSISTANT') unless rows.is_a?(Array)

    rows.each do |row|
      next add_error('INVALID_ASSISTANT') unless row.is_a?(Hash)

      id = parse_id(row['id'])
      state = @assistant_state[id]
      next add_error('INVALID_ASSISTANT', assistant_id: id) unless state

      if row.key?('channel_scope')
        state[:scope] = row['channel_scope']
        add_error('INVALID_SCOPE', assistant_id: id) unless %w[all selected].include?(state[:scope])
      end
      state[:inbox_ids] = [] if state[:scope] == 'all' && !row.key?('inbox_ids')
      next unless row.key?('inbox_ids')

      ids = row['inbox_ids']
      parsed = ids.is_a?(Array) ? ids.map { |value| parse_id(value) } : nil
      if parsed.nil? || parsed.any?(&:nil?) || parsed.any? { |inbox_id| !@inboxes.key?(inbox_id) }
        add_error('INVALID_CHANNEL', assistant_id: id)
      else
        state[:inbox_ids] = state[:scope] == 'all' ? [] : parsed.uniq.sort
      end
    end
  end

  def stage_channels(rows)
    return add_error('INVALID_CHANNEL') unless rows.is_a?(Array)

    rows.each do |row|
      next add_error('INVALID_CHANNEL') unless row.is_a?(Hash)

      id = parse_id(row['inbox_id'])
      state = @channel_state[id]
      next add_error('INVALID_CHANNEL', inbox_id: id) unless state

      if row.key?('ai_enabled')
        if [true, false].include?(row['ai_enabled'])
          state[:ai_enabled] = row['ai_enabled']
        else
          add_error('INVALID_AI_ENABLED', inbox_id: id)
        end
      end
      if row.key?('main_assistant_id')
        value = row['main_assistant_id']
        state[:main_id] = value.nil? ? nil : parse_id(value)
        state[:cleared_main] = value.nil?
        add_error('INVALID_MAIN_AGENT', inbox_id: id) if !value.nil? && state[:main_id].nil?
      end
      if row.key?('auto_reply_mode')
        state[:auto_reply_mode] = row['auto_reply_mode']
        add_error('INVALID_AUTO_REPLY_MODE', inbox_id: id) unless CaptainInbox::AUTO_REPLY_MODES.include?(state[:auto_reply_mode])
      end
      state[:main_id] ||= @default_id if state[:ai_enabled] && state[:link].nil?
    end
  end

  def validate_state
    add_error('INVALID_DEFAULT', assistant_id: @default_id) if @default_id && !@agents[@default_id]&.entry_eligible?
    @channel_state.each do |inbox_id, state|
      main_id = state[:main_id]
      if main_id.nil?
        if state[:ai_enabled] || state[:cleared_main] || state[:auto_reply_mode] != CaptainInbox::DEFAULT_AUTO_REPLY_MODE
          add_error('MAIN_AGENT_REQUIRED', inbox_id: inbox_id)
        end
        next
      end
      agent = @agents[main_id]
      next add_error('INVALID_MAIN_AGENT', inbox_id: inbox_id, assistant_id: main_id) unless agent
      next add_error('MAIN_AGENT_INACTIVE', inbox_id: inbox_id, assistant_id: main_id) unless agent.active?

      membership = @assistant_state[main_id]
      next if membership[:scope] == 'all' || membership[:inbox_ids].include?(inbox_id)

      add_error('MAIN_AGENT_NOT_MEMBER', inbox_id: inbox_id, assistant_id: main_id)
    end
  end

  def save_state
    @assistant_state.each do |id, state|
      agent = @agents.fetch(id)
      current_ids = agent.selected_inbox_ids
      (state[:inbox_ids] - current_ids).each do |inbox_id|
        agent.agent_channels.create!(account: account, inbox_id: inbox_id)
      end
      agent.update!(channel_scope: state[:scope]) if agent.channel_scope != state[:scope]
      agent.agent_channels.where(inbox_id: current_ids - state[:inbox_ids]).delete_all
    end
    @channel_state.each do |inbox_id, state|
      next unless state[:main_id]

      attrs = { captain_assistant_id: state[:main_id], ai_enabled: state[:ai_enabled], auto_reply_mode: state[:auto_reply_mode] }
      if state[:link]
        state[:link].update!(attrs) unless attrs.all? { |key, value| state[:link].public_send(key) == value }
      else
        CaptainInbox.create!(attrs.merge(inbox_id: inbox_id))
      end
    end
    account.update!(captain_default_assistant_id: @default_id) if parse_id(account.captain_default_assistant_id) != @default_id
  end

  def parse_id(value)
    value.to_i if value.to_s.match?(/\A[1-9]\d*\z/)
  end

  def add_error(code, inbox_id: nil, assistant_id: nil)
    @errors << { inbox_id: inbox_id, assistant_id: assistant_id, code: code,
                 message: I18n.t("captain.channel_matrix.#{code.downcase}") }
  end
end
