# frozen_string_literal: true

class Captain::Runtime::PartPlanTool < Captain::Runtime::Tool
  description 'Plan this customer message before using action tools. Split only genuinely separate requests. ' \
              'Link answers, corrections, or cancellations to an existing open part by its exact ID.'
  param :mode, type: 'string', desc: 'answer_myself, handoff, council, or clarify', required: true
  param :parts, type: 'array', desc: 'Request parts with fragment, executor_agent_id, patient, relation, and optional link_part_id; council permits at most three',
                required: true
  param :clarification, type: 'string', desc: 'One precise question only for clarify mode', required: false
  param :answer, type: 'string', desc: 'For one simple part only: final answer verified from supplied context without tools', required: false

  def name = 'plan_request'

  def params_schema
    super.deep_stringify_keys.tap do |schema|
      schema['properties']['parts']['items'] = {
        'type' => 'object', 'additionalProperties' => false,
        'properties' => {
          'fragment' => { 'type' => 'string' },
          'executor_agent_id' => { 'type' => 'integer', 'minimum' => 1 },
          'patient' => { 'type' => 'string' },
          'relation' => { 'type' => 'string', 'enum' => Captain::Runtime::PartRegistry::RELATIONS },
          'object_refs' => { 'type' => 'array', 'items' => {
            'type' => 'object', 'additionalProperties' => false,
            'properties' => { 'type' => { 'type' => 'string' }, 'id' => { 'type' => 'integer', 'minimum' => 1 } },
            'required' => %w[type id]
          } },
          'link_part_id' => { 'type' => %w[string null] },
          'link_action' => { 'type' => 'string', 'enum' => Captain::Runtime::PartRegistry::LINK_ACTIONS }
        },
        'required' => %w[fragment executor_agent_id]
      }
    end
  end

  def perform(tool_context, mode:, parts:, clarification: nil, answer: nil)
    plan = Captain::Runtime::PartRegistry.new(tool_context.run_context.context).accept!(
      mode: mode, parts: parts, clarification: clarification, answer: answer
    )
    { mode: plan[:mode], parts: plan[:parts].map { |part| part.slice('id', 'version', 'executor_agent_id') } }.to_json
  rescue ArgumentError, TypeError, KeyError => e
    Captain::ToolResult.failure(error: e.message, retryable: false,
                                audit: { failure_stage: 'tool_arguments', mutation_executed: false })
  end
end
