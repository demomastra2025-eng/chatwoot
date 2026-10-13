# frozen_string_literal: true

require 'yaml'

# A routing-benchmark fixture file (the v2 schema, README "YAML fixture"). The loader is strict: a key the schema does not know
# (a typo such as `must_not_cal`, at the level of a row of the workspace as well), a tool name that matches no tool, a transfer tool
# name, a `ledger_tool`, an appointment operation without a pinned start, a move without the start it moves from, or a turn after a
# staff handoff without `staff: {status: pending}` is an error, because the scorer would otherwise ignore it in silence.
class Captain::Evals::RoutingBenchmark::Fixture
  class Invalid < ArgumentError; end

  # The counters a fixture lists in `forbidden`. The scorer also computes false_handoff_claim on every turn; a fixture may list it.
  HARD_ZERO_COUNTERS = %w[false_success_claim duplicate_operation wrong_patient internal_text_leak wrong_language].freeze
  LISTABLE_COUNTERS = (HARD_ZERO_COUNTERS + %w[false_handoff_claim]).freeze
  OPERATION_KINDS = %w[create update cancel].freeze
  SYMBOLIC_OPERATION_KEYS = %w[resource service starts_at patient patient_name count previous_starts_at previous_resource].freeze
  OPERATION_KEYS = (%w[model kind params] + SYMBOLIC_OPERATION_KEYS).freeze
  TOP_KEYS = %w[workspace dialogues].freeze
  WORKSPACE_KEYS = %w[agents channels knowledge contacts resources services slots appointments deals].freeze
  AGENT_KEYS = %w[name routing_description instructions tool_ids model].freeze
  DIALOGUE_KEYS = %w[id channel contact rubric turns].freeze
  TURN_KEYS = %w[customer at delay_seconds staff rubric expect].freeze
  EXPECT_KEYS = %w[agent agents council transfers must_call must_not_call must_not_succeed operations acts staff_handoff reply_language
                   forbidden human_request].freeze
  ACT_KEYS = %w[tool agent].freeze
  # The language of the reply: a patient is answered in the language they write in, any language (ru, kk, en, tr ...), written as its
  # ISO 639 code. Only Russian and Kazakh replies are checked (Language.checked?).
  REPLY_LANGUAGE = /\A[a-z]{2,3}\z/
  STAFF_HANDOFF_VALUES = [true, false, 'any'].freeze
  # `any`: a request whose right route is one transfer to the agent that owns it all, or a council of its parts: neither signal is checked.
  COUNCIL_VALUES = [true, false, 'any'].freeze
  # The keys of the rows of the workspace (the workspace builder reads these and nothing else).
  ROW_KEYS = {
    'channels' => %w[key entry_agent], 'knowledge' => %w[agent question answer], 'contacts' => %w[key name],
    'resources' => %w[key name timezone], 'services' => %w[key name duration_min base_price resources],
    'slots' => %w[resource weekday start_minute end_minute], 'appointments' => %w[resource service contact starts_at], 'deals' => %w[title]
  }.freeze
  # Transfer tools are account-specific names (a hash of the colleague), so a fixture can never list one.
  TRANSFER_TOOL_PREFIXES = %w[handoff_to_ transfer_to_].freeze
  # Tools of the runtime that are no tool of an agent's list: the planning tool of a council and the human handoff.
  RUNTIME_TOOLS = %w[plan_request handoff].freeze
  OFFSET = /(?:Z|[+-]\d{2}:\d{2})\z/

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
    reject_unknown_keys!(data, TOP_KEYS, 'fixture')
    require_hash!(data['workspace'], 'workspace')
    reject_unknown_keys!(workspace, WORKSPACE_KEYS, 'workspace')
    tools_by_agent = validate_agents!
    names = tools_by_agent.keys
    ROW_KEYS.each do |key, allowed|
      next unless workspace.key?(key)

      require_array!(workspace[key], "workspace.#{key}").each do |row|
        require_hash!(row, key.singularize)
        reject_unknown_keys!(row, allowed, "workspace.#{key}")
      end
    end
    channel_keys = validate_channels!(names)
    contact_keys = validate_contacts!
    validate_calendar_keys!
    validate_workspace_records!(names, contact_keys)
    operation_keys = { resources: workspace.fetch('resources', []).pluck('key'), services: workspace.fetch('services', []).pluck('key'),
                       contacts: contact_keys }
    validate_dialogues!(tools_by_agent, channel_keys, contact_keys, operation_keys)
  rescue KeyError => e
    raise Invalid, "Missing fixture field: #{e.key}"
  rescue ArgumentError => e
    raise if e.is_a?(Invalid)

    raise Invalid, "Invalid fixture value: #{e.message}"
  end

  # { agent name => tool ids }
  def validate_agents!
    agents = require_array!(workspace['agents'], 'workspace.agents', nonempty: true)
    tools = agents.to_h do |agent|
      require_hash!(agent, 'agent')
      reject_unknown_keys!(agent, AGENT_KEYS, 'agent')
      require_string!(agent['name'], 'agent.name')
      require_string!(agent['routing_description'], 'agent.routing_description')
      require_string!(agent['instructions'], 'agent.instructions')
      tool_ids = require_array!(agent['tool_ids'], 'agent.tool_ids').map(&:to_s)
      validate_tool_ids!(tool_ids)
      raise Invalid, 'Only openai/gpt-6-luna is allowed' if agent['model'].present? && agent['model'] != 'openai/gpt-6-luna'

      [agent['name'], tool_ids]
    end
    raise Invalid, 'Agent names must be unique' unless tools.size == agents.size

    tools
  end

  def validate_channels!(names)
    channels = workspace.fetch('channels', [{ 'key' => 'default', 'entry_agent' => names.first }])
    channels.each do |channel|
      require_hash!(channel, 'channel')
      require_string!(channel['key'], 'channel.key')
      raise Invalid, 'Channel entry agent is unknown' unless names.include?(channel['entry_agent'])
    end
    keys = channels.pluck('key')
    raise Invalid, 'Channel keys must be unique' unless keys.uniq == keys
    raise Invalid, 'At least one channel is required' if channels.empty?

    keys
  end

  def validate_contacts!
    keys = workspace.fetch('contacts', []).map do |contact|
      require_hash!(contact, 'contact')
      require_string!(contact['key'], 'contact.key')
      require_string!(contact['name'], 'contact.name')
      contact['key']
    end
    raise Invalid, 'Contact keys must be unique' unless keys.uniq == keys

    keys
  end

  def validate_calendar_keys!
    %w[resources services].each do |kind|
      keys = workspace.fetch(kind, []).map do |row|
        require_hash!(row, kind)
        require_string!(row['key'], "#{kind}.key")
        require_string!(row['name'], "#{kind}.name")
        row['key']
      end
      raise Invalid, "#{kind} keys must be unique" unless keys.uniq == keys
    end
    validate_service_links!
  end

  # `services[].resources`: the doctors that perform the service (the price list of a clinic links a service to its doctors). A service
  # that lists none is performed by every doctor of the workspace.
  def validate_service_links!
    resource_keys = workspace.fetch('resources', []).pluck('key')
    workspace.fetch('services', []).each do |row|
      next unless row.key?('resources')

      links = require_array!(row['resources'], "services.#{row['key']}.resources", nonempty: true)
      unknown = links - resource_keys
      raise Invalid, "services.#{row['key']}.resources names an unknown resource: #{unknown.join(', ')}" if unknown.any?
      raise Invalid, "services.#{row['key']}.resources must not repeat a resource" unless links.uniq == links
    end
  end

  def validate_dialogues!(tools_by_agent, channel_keys, contact_keys, operation_keys)
    dialogues = require_array!(data['dialogues'], 'dialogues', nonempty: true)
    ids = dialogues.map do |dialogue|
      require_hash!(dialogue, 'dialogue')
      dialogue['id']
    end
    raise Invalid, 'Dialogue IDs must be unique' unless ids.uniq == ids

    dialogues.each do |dialogue|
      reject_unknown_keys!(dialogue, DIALOGUE_KEYS, 'dialogue')
      require_string!(dialogue['id'], 'dialogue.id')
      raise Invalid, 'Unknown dialogue channel' if dialogue['channel'] && channel_keys.exclude?(dialogue['channel'])
      raise Invalid, 'Unknown dialogue contact' if dialogue['contact'] && contact_keys.exclude?(dialogue['contact'])

      require_string!(dialogue['rubric'], 'dialogue.rubric') if dialogue.key?('rubric')
      turns = require_array!(dialogue['turns'], 'dialogue.turns', nonempty: true)
      turns.each { |turn| validate_turn!(turn, tools_by_agent, operation_keys) }
      validate_staff_returns!(dialogue['id'], turns)
    end
  end

  def validate_turn!(turn, tools_by_agent, operation_keys)
    require_hash!(turn, 'turn')
    reject_unknown_keys!(turn, TURN_KEYS, 'turn')
    require_string!(turn['customer'], 'turn.customer')
    require_string!(turn['rubric'], 'turn.rubric') if turn.key?('rubric')
    require_hash!(turn['expect'], 'turn.expect')
    Time.iso8601(turn['at']) if turn['at']
    if turn.key?('delay_seconds') && (!turn['delay_seconds'].is_a?(Numeric) || turn['delay_seconds'].negative?)
      raise Invalid, 'delay_seconds must be nonnegative'
    end
    validate_staff!(turn['staff']) if turn['staff']
    validate_expectation!(turn['expect'], tools_by_agent, operation_keys)
  end

  def validate_staff!(staff)
    require_hash!(staff, 'turn.staff')
    reject_unknown_keys!(staff, %w[status], 'turn.staff')
    raise Invalid, 'Staff status must be open or pending' unless %w[open pending].include?(staff['status'])
  end

  # A conversation that a staff handoff left open is owned by staff. The fixture says when staff returns it to the AI: the turn
  # after a handoff (staff_handoff true or any) carries `staff: {status: pending}`, or the AI would answer a conversation that
  # nobody gave back.
  def validate_staff_returns!(dialogue_id, turns)
    turns.each_cons(2).with_index(2) do |(previous, turn), number|
      next unless [true, 'any'].include?(previous.dig('expect', 'staff_handoff'))
      next if turn.dig('staff', 'status') == 'pending'

      raise Invalid, "#{dialogue_id} turn #{number} follows a staff handoff and must carry staff: {status: pending}"
    end
  end

  def validate_expectation!(expect, tools_by_agent, operation_keys)
    reject_unknown_keys!(expect, EXPECT_KEYS, 'turn.expect')
    validate_expected_agents!(expect, tools_by_agent.keys)
    council = expect['council']
    raise Invalid, "Expected council must be true, false or 'any' (both routes are right)" unless COUNCIL_VALUES.include?(council)

    validate_tool_lists!(expect, council)
    validate_tool_names!(expect, tools_by_agent)
    validate_v2_values!(expect)
    Array(expect['operations']).each { |operation| validate_operation!(operation, operation_keys) }
    validate_acts!(expect['acts'], tools_by_agent) if expect.key?('acts')
    if expect.key?('human_request') && [true, false].exclude?(expect['human_request'])
      raise Invalid, 'Expected human_request must be true or false'
    end
    require_array!(expect['forbidden'], 'turn.expect.forbidden') if expect.key?('forbidden')
    Array(expect['forbidden']).each do |counter|
      raise Invalid, 'Unknown hard-zero counter' unless LISTABLE_COUNTERS.include?(counter)
    end
  end

  def validate_expected_agents!(expect, names)
    raise Invalid, 'Use either agent or agents in an expectation' if expect.key?('agent') && expect.key?('agents')

    expected = Array(expect['agents'] || expect['agent'])
    raise Invalid, 'Expected acting agent is required' if expected.empty?
    raise Invalid, 'Expected agent is unknown' unless (expected - names).empty?
    raise Invalid, 'agents lists at least two agents; write agent: for one' if expect.key?('agents') && (!expect['agents'].is_a?(Array) || expected.size < 2)
  end

  def validate_tool_lists!(expect, council)
    %w[must_call must_not_call operations must_not_succeed acts].each do |key|
      require_array!(expect[key], "turn.expect.#{key}") if expect.key?(key)
    end
    %w[must_call must_not_call].each do |key|
      Array(expect[key]).each do |name|
        require_string!(name, "turn.expect.#{key} item")
        next unless name.start_with?(*TRANSFER_TOOL_PREFIXES)

        raise Invalid, "turn.expect.#{key} names the transfer tool #{name}: transfer tools are account-specific, count them with expect.transfers"
      end
    end
    if council && Array(expect['must_call']).include?('handoff')
      raise Invalid, 'handoff cannot be in must_call of a council turn: the staff handoff of a council is structural (staff_handoff: true)'
    end

    Array(expect['must_not_succeed']).each do |tool|
      next if mutation_tools.include?(tool)

      raise Invalid, "must_not_succeed names #{tool.inspect}, which is not a mutation tool"
    end
  end

  # A tool name that matches nothing is a silent hole: a typo in `must_not_call` ("cancel_apointment") disables the check of the tool it
  # was meant to forbid. `must_call` names a tool that some agent of the workspace has (or plan_request / handoff), `must_not_call` any
  # tool of the benchmark.
  def validate_tool_names!(expect, tools_by_agent)
    known = self.class.safe_tool_ids | RUNTIME_TOOLS
    owned = tools_by_agent.values.flatten | RUNTIME_TOOLS
    allowed = { 'must_call' => [owned, 'no agent of the workspace has it'], 'must_not_call' => [known, 'it is no tool of the benchmark'] }
    allowed.each do |key, (names, why)|
      Array(expect[key]).each do |name|
        next if names.include?(name)

        raise Invalid, "turn.expect.#{key} names the unknown tool #{name.inspect}: #{why}"
      end
    end
  end

  def mutation_tools = Captain::Evals::RoutingBenchmark::Scorer::MUTATION_TOOLS

  def validate_v2_values!(expect)
    if expect.key?('transfers') && !(expect['transfers'].is_a?(Integer) && [0, 1].include?(expect['transfers']))
      raise Invalid, 'transfers must be the integer 0 or 1'
    end
    if expect.key?('staff_handoff') && STAFF_HANDOFF_VALUES.exclude?(expect['staff_handoff'])
      raise Invalid, "staff_handoff must be true, false or 'any'"
    end
    return unless expect.key?('reply_language')

    language = expect['reply_language']
    raise Invalid, 'reply_language must be a language code such as ru, kk or en' unless language.is_a?(String) && language.match?(REPLY_LANGUAGE)
  end

  # acts: [{tool: create_appointment, agent: Запись к врачу}]: the named agent, and not the planner, made a successful call.
  def validate_acts!(acts, tools_by_agent)
    require_array!(acts, 'turn.expect.acts').each do |act|
      require_hash!(act, 'act')
      reject_unknown_keys!(act, ACT_KEYS, 'act')
      agent = act['agent']
      raise Invalid, "act agent is unknown: #{agent.inspect}" unless tools_by_agent.key?(agent)
      raise Invalid, "act tool #{act['tool'].inspect} is not a mutation tool" unless mutation_tools.include?(act['tool'])
      raise Invalid, "act tool #{act['tool']} is not a tool of #{agent}" unless tools_by_agent.fetch(agent).include?(act['tool'])
    end
  end

  # An expectation of a database change. `params` are database columns; the symbolic keys (resource, service, starts_at,
  # patient, patient_name, count, previous_starts_at, previous_resource) belong to an appointment and are checked by
  # OperationCheck. An appointment operation pins the start (`params.starts_at`, or the symbolic `starts_at`) with an offset: an
  # expectation without it could not tell a wrong time from a right one.
  def validate_operation!(operation, keys)
    require_hash!(operation, 'operation')
    raise Invalid, 'operation.ledger_tool is not supported: the operation ledger holds no tool name' if operation.key?('ledger_tool')

    reject_unknown_keys!(operation, OPERATION_KEYS, 'operation')
    raise Invalid, 'Unknown operation model' unless %w[appointment deal contact].include?(operation['model'])
    raise Invalid, 'Unknown operation kind' unless OPERATION_KINDS.include?(operation.fetch('kind', 'create'))
    raise Invalid, 'Only an appointment can be cancelled' if operation['kind'] == 'cancel' && operation['model'] != 'appointment'

    params = require_hash!(operation.fetch('params', {}), 'operation.params')
    model = Captain::Evals::RoutingBenchmark::Scorer::OPERATION_MODELS.fetch(operation['model'])
    raise Invalid, 'Unknown operation column' unless (params.keys - model.column_names).empty?

    validate_symbolic_operation!(operation, keys)
    validate_pinned_start!(operation)
    validate_move_origin!(operation)
  end

  # A move pins the appointment it starts from. The new start alone cannot tell the move of the right appointment from the move of the
  # wrong one to the requested time (two appointments of the caller, "перенесите на понедельник в 11:00"). A cancellation pins the
  # appointment by its start already (`params.starts_at` is the start of the cancelled appointment).
  def validate_move_origin!(operation)
    return unless operation['model'] == 'appointment' && Captain::Evals::RoutingBenchmark::OperationCheck.kind_of(operation) == 'update'
    return if operation.key?('count') && operation['count'].to_i.zero?
    return if operation['previous_starts_at'].present?

    raise Invalid, 'A move (kind update) must pin previous_starts_at (ISO-8601 with an offset): the start of the appointment it moves'
  end

  def validate_pinned_start!(operation)
    return unless operation['model'] == 'appointment'

    start = operation['starts_at'] || operation.dig('params', 'starts_at')
    # "count: 0" says "no such row": there is no start to pin.
    return if start.nil? && operation.key?('count') && operation['count'].to_i.zero?

    raise Invalid, 'An appointment operation must pin params.starts_at (ISO-8601 with an offset)' if start.nil?
    if operation['starts_at'] && operation.dig('params', 'starts_at') && operation['starts_at'] != operation.dig('params', 'starts_at')
      raise Invalid, 'operation.starts_at and operation.params.starts_at differ'
    end

    require_iso_with_offset!(start, 'operation starts_at')
  end

  def validate_symbolic_operation!(operation, keys)
    return if (SYMBOLIC_OPERATION_KEYS & operation.keys).empty?

    raise Invalid, 'Symbolic operation keys belong to an appointment operation' unless operation['model'] == 'appointment'

    { 'resource' => :resources, 'previous_resource' => :resources, 'service' => :services, 'patient' => :contacts }.each do |field, kind|
      next unless operation.key?(field)

      raise Invalid, "Unknown #{field} in an operation: #{operation[field]}" unless keys.fetch(kind).include?(operation[field])
    end
    %w[starts_at previous_starts_at patient_name].each { |field| require_string!(operation[field], "operation.#{field}") if operation.key?(field) }
    %w[starts_at previous_starts_at].each { |field| require_iso_with_offset!(operation[field], "operation.#{field}") if operation.key?(field) }
    return unless operation.key?('count') && !(operation['count'].is_a?(Integer) && operation['count'].between?(0, 10))

    raise Invalid, 'operation.count must be an integer from 0 to 10'
  end

  def require_iso_with_offset!(value, field)
    raise Invalid, "#{field} must be an ISO-8601 string" unless value.is_a?(String)
    raise Invalid, "#{field} must carry an offset (+05:00), got #{value}" unless value.match?(OFFSET)

    Time.iso8601(value)
  end

  def validate_tool_ids!(tool_ids)
    unsupported = tool_ids - self.class.safe_tool_ids
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

  def reject_unknown_keys!(hash, allowed, where)
    unknown = hash.keys.map(&:to_s) - allowed
    raise Invalid, "Unknown key in #{where}: #{unknown.join(', ')} (allowed: #{allowed.join(', ')})" if unknown.any?
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
