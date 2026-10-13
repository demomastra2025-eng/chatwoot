# frozen_string_literal: true

# The tool calls of one benchmark turn with their arguments, results and owners, for the triage list and for the checks that
# need more than a tool name. The monitoring events (llm.tool.complete) carry the name, the success flag, an argument digest,
# the agent that ran the tool (LlmEvent#assistant_id) and, in a council part, the part. The arguments and a result preview come
# from the audit rows that Captain::ToolExecutionAuditService writes for every executed public tool of an account with the
# audit_logs feature (Workspace turns it on for the synthetic account). An event without an audit row (`audited: false`) did not
# run a public tool body: it is a coordination tool such as plan_request, or a cached replay of an earlier result.
#
# The transfer tool of a colleague has an account-specific name (transfer_to_agent_<id>, formerly handoff_to_<name>); every
# report shows it as the pseudo tool `transfer`.
class Captain::Evals::RoutingBenchmark::ToolTrace
  ACTION = 'captain_tool_execute'
  MAX_ARGUMENTS = 240
  MAX_RESULT = 320
  TRANSFER_TOOL = /\A(?:transfer_to_|handoff_to_)/
  TRANSFER = 'transfer'

  class << self
    # The newest audit row of the account; the turn reads the rows after it.
    def cursor(account)
      audits(account).maximum(:id).to_i
    end

    def audits_after(account, cursor)
      audits(account).where('id > ?', cursor).order(:id).to_a
    end

    # The name a report shows for a tool: the transfer tools of every colleague are `transfer`.
    def display_name(tool_name)
      tool_name.to_s.match?(TRANSFER_TOOL) ? TRANSFER : tool_name.to_s
    end

    # A field of a monitoring event: the recorder moves some payload keys (assistant_id, status, reason, current_agent ...) into
    # columns, so a key may live in either place.
    def field(event, key)
      value = event.payload.to_h.stringify_keys[key.to_s] if event.respond_to?(:payload)
      value = event.public_send(key) if value.nil? && event.respond_to?(key)
      value
    end

    # [{ tool:, success:, audited:, agent:, arguments:, result:, arguments_digest:, part_id:, part_version: }]. Events come in the
    # order the tools finished; an audit row is matched with the next event of the same tool. agent_names maps an assistant id
    # to the name of the agent: `agent` is the agent that ran the tool, else the one the audit row names. Only the llm.tool.complete
    # event of a call is read (any other event about the same operation is ignored), so a call is listed once.
    def build(events:, audits:, agent_names: {})
      pending = audits.group_by { |audit| audit.audited_changes.to_h['tool_id'] }
      calls = events.select { |event| event.event_name == 'llm.tool.complete' }.map do |event|
        entry(event, pending[event.tool_name]&.shift, agent_names)
      end
      calls + pending.values.flatten.map { |audit| entry(nil, audit, agent_names) }
    end

    # The same list with arguments and results reduced to one short line each.
    def compact(calls)
      calls.map do |call|
        line = { tool: call[:tool], success: call[:success] }
        line[:audited] = call[:audited] unless call[:audited].nil?
        line[:agent] = call[:agent] if call[:agent].present?
        line[:part_id] = call[:part_id].to_s.first(8) if call[:part_id].present?
        line[:arguments] = shorten(call[:arguments], MAX_ARGUMENTS) if call[:arguments].present?
        line[:result] = shorten(call[:result], MAX_RESULT) if call[:result].present?
        line
      end
    end

    # Canonical form of arguments (keys sorted), to tell two identical calls from two different ones.
    def canonical(value)
      case value
      when Hash then value.stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    private

    def audits(account)
      Enterprise::AuditLog.where(associated_type: 'Account', associated_id: account.id, action: ACTION)
    end

    def entry(event, audit, agent_names)
      changes = audit&.audited_changes.to_h
      {
        tool: display_name(event&.tool_name || changes['tool_id']),
        success: event ? event.payload['result_success'] : changes['result_success'],
        audited: audit.present?,
        agent: agent_of(event, agent_names) || changes['current_agent'],
        arguments: changes['arguments'],
        result: changes['result_preview'] || changes['result_message'],
        arguments_digest: event ? field(event, 'arguments_digest') : nil,
        part_id: event ? field(event, 'part_id') : nil,
        part_version: event ? field(event, 'part_version') : nil
      }.compact
    end

    def agent_of(event, agent_names)
      return unless event

      id = field(event, 'assistant_id')
      id.present? ? agent_names[id.to_i] : nil
    end

    def shorten(value, limit)
      text = value.is_a?(String) ? value : JSON.generate(value)
      text.squish.truncate(limit)
    rescue StandardError
      value.to_s.truncate(limit)
    end
  end
end
