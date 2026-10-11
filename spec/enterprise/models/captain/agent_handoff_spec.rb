require 'rails_helper'

RSpec.describe Captain::AgentHandoff, type: :model do
  let(:account) { create(:account) }
  let(:source) { create(:captain_assistant, account: account) }
  let(:target) { create(:captain_assistant, account: account) }

  def route_to(agent)
    described_class.new(account: account, source_assistant: source, target_assistant: agent)
  end

  it 'requires both agents to belong to the route workspace' do
    route = route_to(create(:captain_assistant))

    expect(route).not_to be_valid
    expect(route.errors[:account]).to include('must match both agents')
  end

  it 'rejects self routes' do
    route = route_to(source)

    expect(route).not_to be_valid
    expect(route.errors[:target_assistant]).to include('must be a different agent')
  end

  it 'rejects a new inactive target' do
    target.update!(active: false)
    route = route_to(target)

    expect(route).not_to be_valid
    expect(route.errors[:target_assistant]).to include('must be an active external agent')
  end

  it 'rejects a new internal target' do
    target.update!(usage_mode: 'internal_assistant')
    route = route_to(target)

    expect(route).not_to be_valid
    expect(route.errors[:target_assistant]).to include('must be an active external agent')
  end

  { inactive: { active: false }, internal: { usage_mode: 'internal_assistant' } }.each do |state, attributes|
    it "allows an existing route target to become #{state} with its incoming routes loaded" do
      route = route_to(target)
      route.save!
      target.incoming_agent_handoffs.load

      target.update!(attributes)

      expect(target.reload).to have_attributes(attributes)
      expect(route.reload).to have_attributes(source_assistant_id: source.id, target_assistant_id: target.id)
      expect(route).to be_valid
      expect(source.handoff_targets).to be_empty
    end
  end

  it 'enforces workspace boundaries even when model validation is bypassed' do
    foreign_target = create(:captain_assistant)

    expect do
      described_class.transaction(requires_new: true) { route_to(foreign_target).save!(validate: false) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it 'enforces no self routes at the database boundary' do
    expect do
      described_class.transaction(requires_new: true) { route_to(source).save!(validate: false) }
    end.to raise_error(ActiveRecord::StatementInvalid)
  end
end
