require 'uri'

class AgentBots::FlowBuilder::ConfigValidator
  TRIGGER_EVENTS = %w[all_messages first_message keyword].freeze
  NODE_TYPES = AgentBots::FlowBuilder::ConfigNormalizer::SUPPORTED_NODE_TYPES.freeze
  CONVERSATION_STATUSES = Conversation.statuses.keys.freeze
  CONDITION_FIELDS = %w[message_text conversation_status has_label].freeze
  CONDITION_OPERATORS = %w[contains equals].freeze
  WEBHOOK_METHODS = %w[GET POST].freeze

  attr_reader :errors

  def initialize(bot_config:)
    @bot_config = AgentBots::FlowBuilder::ConfigNormalizer.normalize(bot_config).with_indifferent_access
    @errors = []
  end

  def valid?
    validate_root
    errors.empty?
  end

  private

  attr_reader :bot_config

  def validate_root
    errors << 'flow must be a graph' unless nodes.is_a?(Hash)
    return unless nodes.is_a?(Hash)

    errors << 'flow requires at least one trigger node' if trigger_nodes.blank?
    validate_nodes
    validate_connections
  end

  def validate_nodes
    nodes.each_value do |raw_node|
      next unless raw_node.is_a?(Hash)

      node = raw_node.with_indifferent_access
      validate_node_type(node)
      validate_node_payload(node)
    end
  end

  def validate_connections
    nodes.each do |node_id, raw_node|
      next unless raw_node.is_a?(Hash)

      raw_node.with_indifferent_access.fetch(:outputs, {}).each_value do |output|
        Array(output[:connections]).each do |connection|
          target_id = connection['node'].presence || connection[:node].presence
          target_port = connection['output'].presence || connection[:output].presence

          errors << "node #{node_id} has a connection to an unknown node" if target_id.blank? || !nodes.key?(target_id.to_s)
          errors << "node #{node_id} has an invalid target port" unless target_port.to_s.start_with?('input_')
        end
      end
    end
  end

  def validate_node_type(node)
    return if NODE_TYPES.include?(node[:name].to_s)

    errors << "unsupported node type #{node[:name]}"
  end

  def validate_node_payload(node)
    data = (node[:data] || {}).with_indifferent_access

    case node[:name].to_s
    when 'trigger'
      validate_trigger_node(data)
    when 'menu'
      validate_menu_node(node, data)
    when 'message', 'note'
      errors << "node #{node[:id]} requires body text" if data[:body].blank?
    when 'condition'
      validate_condition_node(node, data)
    when 'delay'
      errors << "node #{node[:id]} requires a positive delay" if data[:seconds].to_i <= 0
    when 'change_status', 'handoff'
      validate_status(data[:status], node[:id]) if data[:status].present?
    when 'webhook'
      validate_webhook_node(node, data)
    end
  end

  def validate_trigger_node(data)
    event = data[:event].presence || 'all_messages'
    errors << "unsupported trigger event: #{event}" unless TRIGGER_EVENTS.include?(event)
    return unless event == 'keyword'

    errors << 'keyword trigger requires at least one keyword' if Array(data[:keywords]).blank?
  end

  def validate_menu_node(node, data)
    options = Array(data[:options])
    errors << "node #{node[:id]} menu body is required" if data[:body].blank?
    errors << "node #{node[:id]} menu requires at least one option" if options.blank?

    options.each_with_index do |option, option_index|
      option = option.with_indifferent_access
      errors << "node #{node[:id]} option #{option_index + 1} label is required" if option[:label].blank?
    end

    output_count = node.fetch(:outputs, {}).keys.count
    errors << "node #{node[:id]} is missing outputs for some menu options" if output_count < options.length
  end

  def validate_condition_node(node, data)
    unless CONDITION_FIELDS.include?(data[:field].to_s)
      errors << "node #{node[:id]} has unsupported condition field #{data[:field]}"
    end

    unless CONDITION_OPERATORS.include?(data[:operator].to_s)
      errors << "node #{node[:id]} has unsupported condition operator #{data[:operator]}"
    end

    if data[:field].to_s == 'has_label'
      errors << "node #{node[:id]} requires at least one label" if Array(data[:label_ids]).blank?
    elsif data[:value].blank?
      errors << "node #{node[:id]} requires a comparison value"
    end
  end

  def validate_webhook_node(node, data)
    if data[:url].blank?
      errors << "node #{node[:id]} requires a webhook URL"
      return
    end

    unless data[:url].to_s.match?(URI::DEFAULT_PARSER.make_regexp(%w[http https]))
      errors << "node #{node[:id]} requires a valid http or https URL"
    end

    unless WEBHOOK_METHODS.include?(data[:method].to_s.upcase)
      errors << "node #{node[:id]} has unsupported webhook method #{data[:method]}"
    end
  end

  def validate_status(status, node_id)
    return if CONVERSATION_STATUSES.include?(status.to_s)

    errors << "node #{node_id} has unsupported status #{status}"
  end

  def nodes
    @nodes ||= bot_config.dig(:flow, :drawflow, :Home, :data)
  end

  def trigger_nodes
    @trigger_nodes ||= nodes.to_h.values.select do |raw_node|
      raw_node.is_a?(Hash) && raw_node.with_indifferent_access[:name].to_s == 'trigger'
    end
  end
end
