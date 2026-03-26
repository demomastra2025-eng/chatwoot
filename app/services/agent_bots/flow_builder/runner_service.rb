require 'net/http'
require 'uri'

class AgentBots::FlowBuilder::RunnerService
  STATE_ROOT_KEY = 'agent_bot_runtime'.freeze
  FLOW_STATE_KEY = 'flow_builder'.freeze
  MAX_EXECUTION_STEPS = 100
  WEBHOOK_TIMEOUT_SECONDS = 10

  attr_reader :agent_bot, :message, :conversation

  def initialize(agent_bot:, message: nil, conversation: nil)
    @agent_bot = agent_bot
    @message = message
    @conversation = conversation || message&.conversation
  end

  def perform
    return if conversation.blank?
    return if flow_nodes.blank?
    return unless message&.incoming?
    return if bot_state['disabled']

    return process_waiting_node if bot_state['waiting_for_node_id'].present?

    matching_trigger_nodes.each do |trigger_node|
      execute_node_queue(next_node_ids(trigger_node, 'output_1'))
      break
    end
  rescue StandardError => e
    Rails.logger.error("[AgentBot FlowBuilder #{agent_bot.id}] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n")) if e.backtrace.present?
  end

  def resume(node_ids:)
    return if conversation.blank?
    return if flow_nodes.blank?
    return if bot_state['disabled']

    execute_node_queue(node_ids)
  rescue StandardError => e
    Rails.logger.error("[AgentBot FlowBuilder Resume #{agent_bot.id}] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n")) if e.backtrace.present?
  end

  private

  def config
    @config ||= AgentBots::FlowBuilder::ConfigNormalizer.normalize(agent_bot.bot_config).with_indifferent_access
  end

  def flow_nodes
    @flow_nodes ||= begin
      raw_nodes = config.dig(:flow, :drawflow, :Home, :data) || {}
      raw_nodes.each_with_object({}) do |(id, node), acc|
        acc[id.to_s] = node.with_indifferent_access if node.is_a?(Hash)
      end
    end
  end

  def bot_state
    @bot_state ||= begin
      runtime = (conversation.additional_attributes || {}).with_indifferent_access
      runtime.dig(STATE_ROOT_KEY, FLOW_STATE_KEY, agent_bot.id.to_s).presence || {}
    end
  end

  def matching_trigger_nodes
    flow_nodes.values.select do |node|
      next false unless node[:name].to_s == 'trigger'

      trigger_matched?(node)
    end
  end

  def process_waiting_node
    waiting_node = flow_nodes[bot_state['waiting_for_node_id'].to_s]
    return clear_state! if waiting_node.blank?

    case waiting_node[:name].to_s
    when 'menu'
      process_waiting_menu(waiting_node)
    else
      clear_state!
    end
  end

  def process_waiting_menu(menu_node)
    matched_option = matched_menu_option(menu_node)
    unless matched_option.present?
      invalid_reply_message = menu_node.dig(:data, :invalid_reply_message)
      send_bot_message(invalid_reply_message) if invalid_reply_message.present?
      return
    end

    clear_state!
    execute_node_queue(next_node_ids(menu_node, matched_option[:output_key]))
  end

  def execute_node_queue(node_ids)
    steps_processed = 0
    queue = Array(node_ids).flatten.compact.map(&:to_s)

    while queue.any? && steps_processed < MAX_EXECUTION_STEPS
      node_id = queue.shift
      node = flow_nodes[node_id]
      next if node.blank?

      steps_processed += 1
      result = execute_node(node)

      case result[:status]
      when :continue
        queue = Array(result[:next_node_ids]).map(&:to_s) + queue
      when :waiting, :scheduled, :handoff
        return
      end
    end

    clear_state!
  end

  def execute_node(node)
    case node[:name].to_s
    when 'message'
      send_bot_message(node.dig(:data, :body))
      continue_result(node)
    when 'note'
      send_private_note(node.dig(:data, :body))
      continue_result(node)
    when 'menu'
      send_menu(node)
      persist_state!(
        'waiting_for_node_id' => node[:id].to_s,
        'waiting_for_node_type' => node[:name].to_s,
        'last_node_id' => node[:id].to_s
      )
      { status: :waiting }
    when 'condition'
      {
        status: :continue,
        next_node_ids: next_node_ids(node, condition_passed?(node) ? 'output_1' : 'output_2')
      }
    when 'delay'
      schedule_resume(node)
      { status: :scheduled }
    when 'add_label'
      action_service.add_label(label_titles(node.dig(:data, :label_ids)))
      continue_result(node)
    when 'remove_label'
      action_service.remove_label(label_titles(node.dig(:data, :label_ids)))
      continue_result(node)
    when 'assign_team'
      team_id = node.dig(:data, :team_id)
      action_service.assign_team([team_id.to_i]) if team_id.present?
      continue_result(node)
    when 'assign_agent'
      agent_id = node.dig(:data, :agent_id)
      action_service.assign_agent([agent_id.to_i]) if agent_id.present?
      continue_result(node)
    when 'change_status'
      status = node.dig(:data, :status)
      action_service.change_status([status]) if status.present?
      continue_result(node)
    when 'handoff'
      apply_handoff(node)
      persist_state!(
        'disabled' => node.dig(:data, :disable_bot),
        'last_node_id' => node[:id].to_s
      )
      { status: :handoff }
    when 'webhook'
      execute_webhook(node)
      continue_result(node)
    else
      continue_result(node)
    end
  end

  def continue_result(node)
    {
      status: :continue,
      next_node_ids: next_node_ids(node, 'output_1')
    }
  end

  def trigger_matched?(node)
    event = node.dig(:data, :event).presence || 'all_messages'

    case event
    when 'all_messages'
      true
    when 'first_message'
      conversation.messages.incoming.where.not(id: message.id).none?
    when 'keyword'
      keywords_for(node).any? do |keyword|
        normalized_message_content.include?(normalize_text(keyword))
      end
    else
      false
    end
  end

  def keywords_for(node)
    Array(node.dig(:data, :keywords)).map { |keyword| normalize_text(keyword) }.reject(&:blank?)
  end

  def matched_menu_option(menu_node)
    options = Array(menu_node.dig(:data, :options)).map.with_index do |option, index|
      option = option.with_indifferent_access
      option.merge(index: index + 1, output_key: "output_#{index + 1}")
    end

    options.find do |option|
      [
        option[:label],
        option[:value],
        option[:index]
      ].compact.map { |value| normalize_text(value) }.include?(normalized_message_content)
    end
  end

  def next_node_ids(node, output_key = 'output_1')
    Array(node.dig(:outputs, output_key, :connections)).filter_map do |connection|
      target_node_id = connection['node'].presence || connection[:node].presence
      target_node_id.to_s if target_node_id.present? && flow_nodes.key?(target_node_id.to_s)
    end
  end

  def send_menu(node)
    options_text = Array(node.dig(:data, :options)).map.with_index do |option, index|
      option = option.with_indifferent_access
      "#{index + 1}. #{option[:label]}"
    end.join("\n")

    body = [node.dig(:data, :body), options_text].reject(&:blank?).join("\n\n")
    send_bot_message(body)
  end

  def condition_passed?(node)
    field = node.dig(:data, :field).to_s
    operator = node.dig(:data, :operator).to_s
    value = node.dig(:data, :value).to_s

    case field
    when 'message_text'
      compare_values(current_message_content, value, operator)
    when 'conversation_status'
      compare_values(conversation.status.to_s, value, operator)
    when 'has_label'
      label_titles(node.dig(:data, :label_ids)).any? do |label_title|
        conversation.label_list.include?(label_title)
      end
    else
      false
    end
  end

  def compare_values(current_value, expected_value, operator)
    case operator
    when 'equals'
      normalize_text(current_value) == normalize_text(expected_value)
    else
      normalize_text(current_value).include?(normalize_text(expected_value))
    end
  end

  def schedule_resume(node)
    seconds = [[node.dig(:data, :seconds).to_i, 1].max, 86_400].min
    target_node_ids = next_node_ids(node, 'output_1')
    return if target_node_ids.blank?

    AgentBots::FlowBuilder::ResumeJob.set(wait: seconds.seconds).perform_later(
      agent_bot.id,
      conversation.id,
      target_node_ids
    )
  end

  def apply_handoff(node)
    send_private_note(node.dig(:data, :note)) if node.dig(:data, :note).present?

    team_id = node.dig(:data, :team_id)
    agent_id = node.dig(:data, :agent_id)
    status = node.dig(:data, :status)

    action_service.assign_team([team_id.to_i]) if team_id.present?
    action_service.assign_agent([agent_id.to_i]) if agent_id.present?
    action_service.change_status([status]) if status.present?
  end

  def execute_webhook(node)
    url = node.dig(:data, :url).to_s
    return if url.blank?

    uri = URI.parse(url)
    payload = webhook_payload

    request = if node.dig(:data, :method).to_s.upcase == 'GET'
                uri.query = URI.encode_www_form(payload)
                Net::HTTP::Get.new(uri)
              else
                req = Net::HTTP::Post.new(uri)
                req['Content-Type'] = 'application/json'
                req.body = payload.to_json
                req
              end

    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: WEBHOOK_TIMEOUT_SECONDS,
      read_timeout: WEBHOOK_TIMEOUT_SECONDS
    ) do |http|
      http.request(request)
    end
  rescue StandardError => e
    Rails.logger.error("[AgentBot FlowBuilder Webhook #{agent_bot.id}] #{e.class}: #{e.message}")
  end

  def webhook_payload
    {
      agent_bot_id: agent_bot.id,
      conversation: {
        id: conversation.id,
        display_id: conversation.display_id,
        status: conversation.status,
        inbox_id: conversation.inbox_id
      },
      contact: {
        id: conversation.contact_id,
        name: conversation.contact&.name,
        email: conversation.contact&.email,
        phone_number: conversation.contact&.phone_number
      },
      message: {
        id: message&.id,
        content: message&.content
      }
    }
  end

  def send_bot_message(content, private: false)
    return if content.blank?

    Messages::MessageBuilder.new(
      agent_bot,
      conversation,
      {
        content: interpolate_content(content),
        private: private,
        sender_type: 'AgentBot',
        sender_id: agent_bot.id
      }
    ).perform
  end

  def send_private_note(content)
    send_bot_message(content, private: true)
  end

  def interpolate_content(content)
    return content if content.blank?

    content.to_s.gsub(/\{\{([\w.]+)\}\}/) do |match|
      scope, field = Regexp.last_match(1).to_s.split('.', 2)

      case scope
      when 'contact'
        interpolate_contact(field) || match
      when 'conversation'
        interpolate_conversation(field) || match
      when 'inbox'
        interpolate_inbox(field) || match
      else
        match
      end
    end
  rescue StandardError
    content.to_s
  end

  def interpolate_contact(field)
    case field
    when 'name' then conversation.contact&.name.to_s
    when 'email' then conversation.contact&.email.to_s
    when 'phone' then conversation.contact&.phone_number.to_s
    when 'id' then conversation.contact_id.to_s
    else
      conversation.contact&.custom_attributes&.dig(field).to_s
    end
  end

  def interpolate_conversation(field)
    case field
    when 'id' then conversation.display_id.to_s
    when 'status' then conversation.status.to_s
    when 'priority' then conversation.priority.to_s
    end
  end

  def interpolate_inbox(field)
    field == 'name' ? conversation.inbox&.name.to_s : nil
  end

  def action_service
    @action_service ||= ActionService.new(conversation)
  end

  def label_titles(label_ids)
    return [] if label_ids.blank?

    conversation.account.labels.where(id: Array(label_ids)).pluck(:title)
  end

  def persist_state!(state)
    additional_attributes = (conversation.additional_attributes || {}).deep_dup
    additional_attributes[STATE_ROOT_KEY] ||= {}
    additional_attributes[STATE_ROOT_KEY][FLOW_STATE_KEY] ||= {}
    additional_attributes[STATE_ROOT_KEY][FLOW_STATE_KEY][agent_bot.id.to_s] = state.merge('updated_at' => Time.current.iso8601)
    conversation.update!(additional_attributes: additional_attributes)
    @bot_state = state
  end

  def clear_state!
    additional_attributes = (conversation.additional_attributes || {}).deep_dup
    flow_state = additional_attributes.dig(STATE_ROOT_KEY, FLOW_STATE_KEY)
    flow_state&.delete(agent_bot.id.to_s)
    conversation.update!(additional_attributes: additional_attributes)
    @bot_state = {}
  end

  def current_message_content
    @current_message_content ||= begin
      source_message = message || conversation.messages.incoming.order(created_at: :desc).first
      source_message&.content.to_s
    end
  end

  def normalized_message_content
    @normalized_message_content ||= normalize_text(current_message_content)
  end

  def normalize_text(value)
    value.to_s.downcase.strip.squish
  end
end
