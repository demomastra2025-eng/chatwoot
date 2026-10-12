# frozen_string_literal: true

require 'yaml'

class Captain::Evals::RoutingBenchmark::Fixture
  class Invalid < ArgumentError; end
  HARD_ZERO_COUNTERS = %w[false_success_claim duplicate_operation wrong_patient internal_text_leak wrong_language].freeze

  attr_reader :data

  def initialize(data)
    @data = data.is_a?(Hash) ? data.deep_stringify_keys : data
    validate!
  end

  def self.load(path)
    new(YAML.safe_load_file(path, permitted_classes: [], aliases: false))
  rescue Psych::Exception => e
    raise Invalid, "Invalid YAML: #{e.message}"
  end

  # Derived from Captain::ToolRegistry (see SafeTools), never a hand-kept list.
  def self.safe_tool_ids = Captain::Evals::RoutingBenchmark::SafeTools.ids

  def workspace = data.fetch('workspace')
  def dialogues = data.fetch('dialogues')

  private

  def validate!
    require_hash!(data, 'fixture')
    require_hash!(data['workspace'], 'workspace')
    agents = require_array!(workspace['agents'], 'workspace.agents', nonempty: true)
    names = agents.map do |agent|
      require_hash!(agent, 'agent')
      require_string!(agent['name'], 'agent.name')
      require_string!(agent['routing_description'], 'agent.routing_description')
      require_string!(agent['instructions'], 'agent.instructions')
      validate_tool_ids!(require_array!(agent['tool_ids'], 'agent.tool_ids'))
      raise Invalid, 'Only openai/gpt-6-luna is allowed' if agent['model'].present? && agent['model'] != 'openai/gpt-6-luna'

      agent['name']
    end
    raise Invalid, 'Agent names must be unique' unless names.uniq == names

    %w[channels knowledge contacts resources services slots appointments deals].each do |key|
      require_array!(workspace[key], "workspace.#{key}") if workspace.key?(key)
    end
    channels = workspace.fetch('channels', [{ 'key' => 'default', 'entry_agent' => names.first }])
    channels.each do |channel|
      require_hash!(channel, 'channel')
      require_string!(channel['key'], 'channel.key')
      raise Invalid, 'Channel entry agent is unknown' unless names.include?(channel['entry_agent'])
    end
    raise Invalid, 'Channel keys must be unique' unless channels.pluck('key').uniq == channels.pluck('key')
    raise Invalid, 'At least one channel is required' if channels.empty?
    contact_keys = workspace.fetch('contacts', []).map do |contact|
      require_hash!(contact, 'contact')
      require_string!(contact['key'], 'contact.key')
      require_string!(contact['name'], 'contact.name')
      contact['key']
    end
    raise Invalid, 'Contact keys must be unique' unless contact_keys.uniq == contact_keys
    %w[resources services].each do |kind|
      keys = workspace.fetch(kind, []).map do |row|
        require_hash!(row, kind)
        require_string!(row['key'], "#{kind}.key")
        require_string!(row['name'], "#{kind}.name")
        row['key']
      end
      raise Invalid, "#{kind} keys must be unique" unless keys.uniq == keys
    end
    validate_workspace_records!(names, contact_keys)
    dialogues = require_array!(data['dialogues'], 'dialogues', nonempty: true)
    ids = dialogues.map do |dialogue|
      require_hash!(dialogue, 'dialogue')
      dialogue['id']
    end
    raise Invalid, 'Dialogue IDs must be unique' unless ids.uniq == ids
    dialogues.each do |dialogue|
      require_hash!(dialogue, 'dialogue')
      require_string!(dialogue['id'], 'dialogue.id')
      raise Invalid, 'Unknown dialogue channel' if dialogue['channel'] && channels.pluck('key').exclude?(dialogue['channel'])
      raise Invalid, 'Unknown dialogue contact' if dialogue['contact'] && contact_keys.exclude?(dialogue['contact'])
      require_string!(dialogue['rubric'], 'dialogue.rubric') if dialogue.key?('rubric')
      require_array!(dialogue['turns'], 'dialogue.turns', nonempty: true).each do |turn|
        require_hash!(turn, 'turn')
        require_string!(turn['customer'], 'turn.customer')
        require_hash!(turn['expect'], 'turn.expect')
        expected_agents = Array(turn.dig('expect', 'agents') || turn.dig('expect', 'agent'))
        raise Invalid, 'Expected acting agent is required' if expected_agents.empty?
        raise Invalid, 'Expected agent is unknown' unless (expected_agents - names).empty?

        %w[must_call must_not_call operations forbidden].each do |key|
          require_array!(turn.dig('expect', key), "turn.expect.#{key}") if turn['expect'].key?(key)
        end
        Array(turn.dig('expect', 'operations')).each do |operation|
          require_hash!(operation, 'operation')
          raise Invalid, 'Unknown operation model' unless %w[appointment deal contact].include?(operation['model'])
          raise Invalid, 'Unknown operation kind' unless %w[create update].include?(operation.fetch('kind', 'create'))
          params = require_hash!(operation.fetch('params', {}), 'operation.params')
          model = Captain::Evals::RoutingBenchmark::Scorer::OPERATION_MODELS.fetch(operation['model'])
          raise Invalid, 'Unknown operation column' unless (params.keys - model.column_names).empty?
          require_string!(operation['ledger_tool'], 'operation.ledger_tool') if operation.key?('ledger_tool')
        end
        Array(turn.dig('expect', 'forbidden')).each do |counter|
          raise Invalid, 'Unknown hard-zero counter' unless HARD_ZERO_COUNTERS.include?(counter)
        end
        Time.iso8601(turn['at']) if turn['at']
        if turn.key?('delay_seconds') && (!turn['delay_seconds'].is_a?(Numeric) || turn['delay_seconds'].negative?)
          raise Invalid, 'delay_seconds must be nonnegative'
        end
        if turn['staff']
          require_hash!(turn['staff'], 'turn.staff')
          raise Invalid, 'Staff status must be open or pending' unless %w[open pending].include?(turn['staff']['status'])
        end
        council = turn.dig('expect', 'council')
        raise Invalid, 'Expected council must be true or false' unless [true, false].include?(council)
      end
    end
  rescue KeyError => e
    raise Invalid, "Missing fixture field: #{e.key}"
  rescue ArgumentError => e
    raise if e.is_a?(Invalid)

    raise Invalid, "Invalid fixture value: #{e.message}"
  end

  def validate_tool_ids!(tool_ids)
    unsupported = tool_ids.map(&:to_s) - self.class.safe_tool_ids
    raise Invalid, "Unsupported benchmark tool: #{unsupported.join(', ')}" unless unsupported.empty?
  end

  def validate_workspace_records!(agent_names, contact_keys)
    workspace.fetch('knowledge', []).each do |row|
      require_hash!(row, 'knowledge')
      require_string!(row['question'], 'knowledge.question')
      require_string!(row['answer'], 'knowledge.answer')
      raise Invalid, 'Knowledge agent is unknown' if row['agent'] && agent_names.exclude?(row['agent'])
    end
    resource_keys = workspace.fetch('resources', []).pluck('key')
    service_keys = workspace.fetch('services', []).pluck('key')
    workspace.fetch('slots', []).each do |row|
      require_hash!(row, 'slot')
      raise Invalid, 'Slot resource is unknown' unless resource_keys.include?(row['resource'])
      raise Invalid, 'Slot weekday is invalid' unless row['weekday'].is_a?(Integer) && row['weekday'].between?(0, 6)
      unless row['start_minute'].is_a?(Integer) && row['end_minute'].is_a?(Integer) && row['start_minute'] < row['end_minute']
        raise Invalid, 'Slot minute range is invalid'
      end
    end
    workspace.fetch('appointments', []).each do |row|
      require_hash!(row, 'appointment')
      raise Invalid, 'Appointment resource is unknown' unless resource_keys.include?(row['resource'])
      raise Invalid, 'Appointment contact is unknown' unless contact_keys.include?(row['contact'])
      raise Invalid, 'Appointment service is unknown' if row['service'] && service_keys.exclude?(row['service'])
      Time.iso8601(row.fetch('starts_at'))
    end
    workspace.fetch('deals', []).each do |row|
      require_hash!(row, 'deal')
      require_string!(row['title'], 'deal.title')
    end
  end

  def require_hash!(value, field)
    raise Invalid, "#{field} must be a mapping" unless value.is_a?(Hash)

    value
  end

  def require_array!(value, field, nonempty: false)
    raise Invalid, "#{field} must be an array" unless value.is_a?(Array)
    raise Invalid, "#{field} must not be empty" if nonempty && value.empty?

    value
  end

  def require_string!(value, field)
    raise Invalid, "#{field} must be a nonempty string" unless value.is_a?(String) && value.strip.present?
  end
end
