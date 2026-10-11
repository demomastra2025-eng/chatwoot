# frozen_string_literal: true

class Reports::AiAgentTransfersQuery
  def initialize(account:, date_range:, assistant_id: nil)
    @account, @date_range, @assistant_id = account, date_range, assistant_id
  end

  def perform
    scope = LlmEvent.where(account_id: @account.id, event_name: 'captain.agent.transfer',
                           created_at: @date_range.from_at...@date_range.until_at)
                    .where("payload ->> 'run_source' = 'live'")
    scope = scope.where("payload ->> 'from_agent_id' = ?", @assistant_id.to_s) if @assistant_id
    transfers = scope.order(:created_at, :id).to_a
    request_ids = transfers.filter_map(&:request_id).uniq
    handoffs = LlmEvent.where(account_id: @account.id, event_name: 'captain.agent.staff_handoff', request_id: request_ids)
                       .where("payload ->> 'run_source' = 'live'").pluck(:request_id).to_set
    guards = LlmEvent.where(account_id: @account.id, event_name: 'captain.agent.transfer_guard',
                            created_at: @date_range.from_at...@date_range.until_at)
                     .where("payload ->> 'run_source' = 'live'")
    guards = guards.where("payload ->> 'from_agent_id' = ?", @assistant_id.to_s) if @assistant_id
    {
      transfers: transfers.map do |event|
        { from_agent_id: event.payload['from_agent_id'], to_agent_id: event.payload['to_agent_id'],
          conversation_id: event.conversation_id, request_id: event.request_id,
          staff_handoff_same_request: handoffs.include?(event.request_id) }
      end,
      guard_count: guards.count
    }
  end
end
