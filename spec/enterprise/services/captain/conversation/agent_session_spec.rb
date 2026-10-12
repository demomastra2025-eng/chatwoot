require 'rails_helper'

RSpec.describe Captain::Conversation::AgentSession do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) do
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant, reply_to_open_conversations: false)
    create(:conversation, account: account, inbox: inbox, status: :pending)
  end
  let(:session) do
    described_class.new(entry: assistant, conversation: conversation,
                        fence: { control_generation: conversation.captain_control_generation })
  end

  before { allow(Llm::EventBus).to receive(:publish) }

  def reserve(scope: 'request:synthetic', tool: 'create_appointment')
    session.reserve_operation(scope: scope, tool: tool, arguments: { slot_id: 9 }, actor_id: assistant.id)
  end

  def stored_operations
    described_class.new(entry: assistant, conversation: conversation).read.fetch('operations')
  end

  def store_part(version)
    session.change do |data|
      data['parts'] = [{ 'id' => 'synthetic-part', 'version' => version, 'executor_agent_id' => assistant.id, 'state' => 'open' }]
    end
  end

  it 'records the outcome of a started action after staff took over, without sending anything' do
    _, key = reserve
    conversation.update!(status: :open)

    expect { session.change { |data| data } }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /status_changed/)
    expect { session.finish_operation(key, { success: true, data: { appointment_id: 17 } }) }
      .not_to(change { conversation.messages.outgoing.count })
    expect(stored_operations[key]).to include('status' => 'finished', 'result' => hash_including('success' => true))
  end

  it 'releases a claim that never reached the provider even when the run is no longer current' do
    _, key = reserve
    conversation.update!(status: :open)

    session.release_unexecuted_operation(key)

    expect(stored_operations).to be_empty
  end

  it 'still refuses to claim a new action once the run is no longer current' do
    conversation.update!(status: :open)

    expect { reserve }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
  end

  it 'blocks the same action in a new part version while the earlier version has no recorded outcome' do
    store_part(1)
    first_status, = reserve(scope: 'part:synthetic-part:v1')
    store_part(2)

    status, receipt = reserve(scope: 'part:synthetic-part:v2')
    other_tool_status, = reserve(scope: 'part:synthetic-part:v2', tool: 'cancel_appointment')

    expect(first_status).to eq(:reserved)
    expect(status).to eq(:existing)
    expect(receipt).to include('status' => 'blocked', 'reason' => 'mutation_retry_blocked')
    expect(other_tool_status).to eq(:reserved)
  end

  it 'allows a new part version once the earlier action recorded its outcome' do
    store_part(1)
    _, key = reserve(scope: 'part:synthetic-part:v1')
    session.finish_operation(key, { success: false, error: 'Slot is taken', audit: { mutation_executed: false } })
    store_part(2)

    status, = reserve(scope: 'part:synthetic-part:v2')

    expect(status).to eq(:reserved)
  end
end
