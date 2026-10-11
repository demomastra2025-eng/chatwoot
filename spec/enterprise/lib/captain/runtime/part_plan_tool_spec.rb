require 'rails_helper'

RSpec.describe Captain::Runtime::PartPlanTool do
  it 'requires a valid nested part with an executor and fragment' do
    schema = described_class.new.params_schema.deep_stringify_keys
    valid = { 'mode' => 'answer_myself', 'parts' => [{ 'fragment' => 'Цена', 'executor_agent_id' => 1 }] }

    expect(JSONSchemer.schema(schema).valid?(valid)).to be(true)
    expect(JSONSchemer.schema(schema).valid?(valid.deep_dup.tap { |item| item['parts'][0].delete('executor_agent_id') })).to be(false)
  end
end

RSpec.describe Captain::Runtime::ToolWrapper do
  let(:action) { double('action tool', name: 'create_deal', description: 'Create deal', metadata: { risk_level: 'high' }) }
  let(:context) { { state: { assistant_id: 1 }, agent_session: Object.new, agent_tasks: [] } }
  let(:wrapper) { described_class.new(action, Captain::Runtime::RunContext.new(context)) }

  it 'blocks a mutating tool before the plan is accepted' do
    result = wrapper.send(:part_plan_error)
    expect(Captain::ToolResult.normalize(result)).to include(success: false, error: /Plan the request/)
    context[:part_plan_accepted] = true
    expect(wrapper.send(:part_plan_error)).to be_nil
  end

  it 'blocks a mutating tool in a consult even with an accepted plan' do
    context[:part_plan_accepted] = true
    context[:consult_mode] = true

    result = wrapper.send(:part_plan_error)
    expect(Captain::ToolResult.normalize(result)).to include(success: false, error: /consult mode/)
  end
end

RSpec.describe Captain::Runtime::ConsultTools do
  it 'allows only declared read-only tools' do
    tool = Struct.new(:name, :metadata)
    expect(described_class.allowed?(tool.new('list_my_deals', { risk_level: 'low' }))).to be(true)
    expect(described_class.allowed?(tool.new('create_deal', { risk_level: 'low' }))).to be(false)
    expect(described_class.allowed?(tool.new('get_my_contact', { risk_level: 'high' }))).to be(false)
  end
end
