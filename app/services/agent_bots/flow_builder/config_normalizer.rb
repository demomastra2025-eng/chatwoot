class AgentBots::FlowBuilder::ConfigNormalizer
  FLOW_VERSION = 2
  MODULE_NAME = 'Home'.freeze
  SUPPORTED_NODE_TYPES = %w[
    trigger
    message
    menu
    condition
    delay
    note
    add_label
    remove_label
    assign_team
    assign_agent
    change_status
    handoff
    webhook
  ].freeze

  class << self
    def normalize(bot_config)
      config = bot_config.is_a?(Hash) ? bot_config.deep_stringify_keys : {}
      return default_config if config.blank?
      return normalize_graph_config(config) if graph_config?(config)
      return normalize_linear_config(config) if linear_config?(config)

      default_config
    end

    def default_config
      trigger_id = default_trigger_id
      trigger_node = build_node(
        id: trigger_id,
        type: 'trigger',
        x: 140,
        y: 200,
        data: {
          'event' => 'all_messages',
          'keywords' => []
        }
      )

      {
        'version' => FLOW_VERSION,
        'flow' => flow_payload(trigger_id => trigger_node)
      }
    end

    private

    def graph_config?(config)
      config.dig('flow', 'drawflow', MODULE_NAME, 'data').is_a?(Hash) ||
        config.dig('drawflow', MODULE_NAME, 'data').is_a?(Hash)
    end

    def linear_config?(config)
      config.key?('steps') || config.key?('trigger')
    end

    def normalize_graph_config(config)
      flow = (config['flow'] || config).deep_stringify_keys
      nodes = flow.dig('drawflow', MODULE_NAME, 'data')
      nodes = {} unless nodes.is_a?(Hash)

      normalized_nodes = nodes.each_with_object({}) do |(raw_id, raw_node), acc|
        next unless raw_node.is_a?(Hash)

        node = raw_node.deep_stringify_keys
        type = node['name'].presence || node['class'].presence
        id = (node['id'].presence || raw_id).to_s
        next if id.blank?

        acc[id] = {
          'id' => id,
          'name' => type.to_s,
          'data' => normalize_node_data(type, node['data']),
          'class' => node['class'].presence || type.to_s,
          'html' => node['html'].to_s,
          'inputs' => normalize_inputs(type, node['inputs']),
          'outputs' => normalize_outputs(type, node['outputs'], node['data']),
          'pos_x' => node['pos_x'].to_i,
          'pos_y' => node['pos_y'].to_i
        }
      end

      {
        'version' => config['version'].presence || FLOW_VERSION,
        'flow' => flow_payload(normalized_nodes)
      }
    end

    def normalize_linear_config(config)
      steps = Array(config['steps']).map { |step| step.is_a?(Hash) ? step.deep_stringify_keys : {} }
      nodes = {}
      step_ids = []

      trigger_id = default_trigger_id
      nodes[trigger_id] = build_node(
        id: trigger_id,
        type: 'trigger',
        x: 140,
        y: 200,
        data: normalize_trigger_data(config['trigger'])
      )

      steps.each_with_index do |step, index|
        step_id = step['id'].presence || generated_node_id(step['type'], index)
        step_ids << step_id
        nodes[step_id] = build_node(
          id: step_id,
          type: step['type'],
          x: 520 + (index * 320),
          y: 120 + ((index % 3) * 220),
          data: normalize_node_data(step['type'], step)
        )
      end

      connect_nodes(nodes, trigger_id, step_ids.first) if step_ids.first.present?

      steps.each_with_index do |step, index|
        current_id = step_ids[index]
        next_id = step_ids[index + 1]

        if step['type'].to_s == 'menu'
          options = Array(step['options'])
          option_count = [options.length, 1].max
          ensure_output_count!(nodes[current_id], option_count)

          options.each_with_index do |option, option_index|
            option = option.is_a?(Hash) ? option.deep_stringify_keys : {}
            target_id = option['target_step_id'].presence || next_id
            connect_nodes(nodes, current_id, target_id, "output_#{option_index + 1}") if target_id.present?
          end
        elsif next_id.present?
          connect_nodes(nodes, current_id, next_id)
        end
      end

      {
        'version' => FLOW_VERSION,
        'flow' => flow_payload(nodes)
      }
    end

    def flow_payload(nodes)
      {
        'drawflow' => {
          MODULE_NAME => {
            'data' => nodes
          }
        }
      }
    end

    def build_node(id:, type:, x:, y:, data:)
      {
        'id' => id.to_s,
        'name' => type.to_s,
        'data' => normalize_node_data(type, data),
        'class' => type.to_s,
        'html' => '',
        'inputs' => blank_ports('input', input_count_for(type)),
        'outputs' => blank_ports('output', output_count_for(type, data)),
        'pos_x' => x.to_i,
        'pos_y' => y.to_i
      }
    end

    def normalize_inputs(type, inputs)
      existing_inputs = inputs.is_a?(Hash) ? inputs.deep_stringify_keys : {}
      count = input_count_for(type)

      (1..count).each_with_object({}) do |index, acc|
        key = "input_#{index}"
        acc[key] = {
          'connections' => normalize_input_connections(existing_inputs.dig(key, 'connections'))
        }
      end
    end

    def normalize_outputs(type, outputs, data)
      existing_outputs = outputs.is_a?(Hash) ? outputs.deep_stringify_keys : {}
      count = output_count_for(type, data)

      (1..count).each_with_object({}) do |index, acc|
        key = "output_#{index}"
        acc[key] = {
          'connections' => normalize_output_connections(existing_outputs.dig(key, 'connections'))
        }
      end
    end

    def blank_ports(kind, count)
      (1..count).each_with_object({}) do |index, acc|
        acc["#{kind}_#{index}"] = { 'connections' => [] }
      end
    end

    def normalize_input_connections(connections)
      Array(connections).filter_map do |connection|
        connection = connection.is_a?(Hash) ? connection.deep_stringify_keys : {}
        next if connection['node'].blank? || connection['input'].blank?

        {
          'node' => connection['node'].to_s,
          'input' => connection['input'].to_s
        }
      end
    end

    def normalize_output_connections(connections)
      Array(connections).filter_map do |connection|
        connection = connection.is_a?(Hash) ? connection.deep_stringify_keys : {}
        next if connection['node'].blank? || connection['output'].blank?

        {
          'node' => connection['node'].to_s,
          'output' => connection['output'].to_s
        }
      end
    end

    def normalize_node_data(type, raw_data)
      data = raw_data.is_a?(Hash) ? raw_data.deep_stringify_keys : {}

      case type.to_s
      when 'trigger'
        normalize_trigger_data(data)
      when 'message', 'note'
        { 'body' => data['body'].to_s }
      when 'menu'
        {
          'body' => data['body'].to_s,
          'invalid_reply_message' => data['invalid_reply_message'].to_s,
          'options' => normalize_menu_options(data['options'])
        }
      when 'condition'
        {
          'field' => data['field'].presence || 'message_text',
          'operator' => data['operator'].presence || 'contains',
          'value' => data['value'].to_s,
          'label_ids' => Array(data['label_ids']).map(&:to_s).reject(&:blank?)
        }
      when 'delay'
        {
          'seconds' => [[data['seconds'].to_i, 1].max, 86_400].min
        }
      when 'add_label', 'remove_label'
        {
          'label_ids' => Array(data['label_ids']).map(&:to_s).reject(&:blank?)
        }
      when 'assign_team'
        { 'team_id' => data['team_id'].to_s }
      when 'assign_agent'
        { 'agent_id' => data['agent_id'].to_s }
      when 'change_status'
        { 'status' => data['status'].presence || 'open' }
      when 'handoff'
        {
          'team_id' => data['team_id'].to_s,
          'agent_id' => data['agent_id'].to_s,
          'status' => data['status'].presence || 'open',
          'note' => data['note'].to_s,
          'disable_bot' => ActiveModel::Type::Boolean.new.cast(data.fetch('disable_bot', true))
        }
      when 'webhook'
        {
          'url' => data['url'].to_s,
          'method' => data['method'].presence || 'POST'
        }
      else
        data
      end
    end

    def normalize_trigger_data(raw_data)
      data = raw_data.is_a?(Hash) ? raw_data.deep_stringify_keys : {}
      keywords = data['keywords']
      keywords = keywords.split(',') if keywords.is_a?(String)

      {
        'event' => data['event'].presence || 'all_messages',
        'keywords' => Array(keywords).map { |keyword| keyword.to_s.strip }.reject(&:blank?)
      }
    end

    def normalize_menu_options(raw_options)
      Array(raw_options).filter_map.with_index do |option, index|
        option = option.is_a?(Hash) ? option.deep_stringify_keys : {}
        {
          'id' => option['id'].presence || "option_#{index + 1}",
          'label' => option['label'].to_s,
          'value' => option['value'].to_s
        }
      end
    end

    def input_count_for(type)
      type.to_s == 'trigger' ? 0 : 1
    end

    def output_count_for(type, raw_data)
      data = raw_data.is_a?(Hash) ? raw_data.deep_stringify_keys : {}

      case type.to_s
      when 'menu'
        [Array(data['options']).length, 1].max
      when 'condition'
        2
      else
        1
      end
    end

    def connect_nodes(nodes, source_id, target_id, output_key = 'output_1')
      return if source_id.blank? || target_id.blank?
      return if nodes[source_id].blank? || nodes[target_id].blank?

      ensure_output_port!(nodes[source_id], output_key)
      ensure_input_port!(nodes[target_id], 'input_1')

      output_connections = nodes[source_id].dig('outputs', output_key, 'connections')
      input_connections = nodes[target_id].dig('inputs', 'input_1', 'connections')
      return if output_connections.any? { |connection| connection['node'] == target_id.to_s && connection['output'] == 'input_1' }

      output_connections << { 'node' => target_id.to_s, 'output' => 'input_1' }
      input_connections << { 'node' => source_id.to_s, 'input' => output_key }
    end

    def ensure_output_count!(node, count)
      node['outputs'] = blank_ports('output', count)
    end

    def ensure_output_port!(node, key)
      node['outputs'][key] ||= { 'connections' => [] }
    end

    def ensure_input_port!(node, key)
      node['inputs'][key] ||= { 'connections' => [] }
    end

    def default_trigger_id
      'trigger_root'
    end

    def generated_node_id(type, index)
      "#{type}_#{index + 1}"
    end
  end
end
