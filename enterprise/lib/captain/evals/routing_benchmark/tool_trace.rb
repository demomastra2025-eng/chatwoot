# frozen_string_literal: true

# The tool calls of one benchmark turn with their arguments and results, for the triage list and for the checks that
# need more than a tool name. The monitoring events (llm.tool.complete) carry only the name, the success flag and an
# argument digest. The arguments and a result preview come from the audit rows that Captain::ToolExecutionAuditService
# writes for every executed public tool of an account with the audit_logs feature (Workspace turns it on for the
# synthetic account). An event without an audit row (`audited: false`) did not run a public tool body: it is a
# coordination tool such as plan_request, or a cached replay of an earlier result.
class Captain::Evals::RoutingBenchmark::ToolTrace
  ACTION = 'captain_tool_execute'
  MAX_ARGUMENTS = 240
  MAX_RESULT = 320

  class << self
    # The newest audit row of the account; the turn reads the rows after it.
    def cursor(account)
      audits(account).maximum(:id).to_i
    end

    def audits_after(account, cursor)
      audits(account).where('id > ?', cursor).order(:id).to_a
    end

    # [{ tool:, success:, audited:, agent:, arguments:, result: }]. Events come in the order the tools finished; an
    # audit row is matched with the next event of the same tool.
    def build(events:, audits:)
      pending = audits.group_by { |audit| audit.audited_changes.to_h['tool_id'] }
      calls = events.select { |event| event.event_name == 'llm.tool.complete' }.map do |event|
        entry(event, pending[event.tool_name]&.shift)
      end
      calls + pending.values.flatten.map { |audit| entry(nil, audit) }
    end

    # The same list with arguments and results reduced to one short line each.
    def compact(calls)
      calls.map do |call|
        line = { tool: call[:tool], success: call[:success] }
        line[:audited] = call[:audited] unless call[:audited].nil?
        line[:agent] = call[:agent] if call[:agent].present?
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

    def entry(event, audit)
      changes = audit&.audited_changes.to_h
      {
        tool: event&.tool_name || changes['tool_id'],
        success: event ? event.payload['result_success'] : changes['result_success'],
        audited: audit.present?,
        agent: changes['current_agent'],
        arguments: changes['arguments'],
        result: changes['result_preview'] || changes['result_message']
      }.compact
    end

    def shorten(value, limit)
      text = value.is_a?(String) ? value : JSON.generate(value)
      text.squish.truncate(limit)
    rescue StandardError
      value.to_s.truncate(limit)
    end
  end
end
