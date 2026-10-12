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

  describe 'the receipt of an action' do
    it 'stores what happened: success, not executed or unknown, read from the result when it is not given' do
      store_part(1)
      outcomes = [
        [{ success: true, data: { appointment_id: 7 } }, 'success'],
        [{ success: false, error: 'Rejected', audit: { mutation_executed: false } }, 'not_executed'],
        [JSON.generate(success: false, reason: 'time_taken'), 'not_executed'],
        [{ success: false, error: 'Provider did not answer', retryable: false }, 'unknown']
      ]

      outcomes.each_with_index do |(result, expected), index|
        _, key = reserve(scope: 'part:synthetic-part:v1', tool: "tool_#{index}")
        session.finish_operation(key, result)

        expect(stored_operations[key]).to include('status' => 'finished', 'outcome' => expected)
      end
    end

    it 'takes the outcome that the caller gives' do
      _, key = reserve
      session.finish_operation(key, { success: false, error: 'x' }, outcome: 'not_executed')

      expect(stored_operations[key]['outcome']).to eq('not_executed')
    end
  end

  describe 'the memory of the earlier versions of a part' do
    def finish_version(version, result, outcome: nil, arguments: { slot_id: 9 })
      store_part(version)
      status, key = session.reserve_operation(scope: "part:synthetic-part:v#{version}", tool: 'create_appointment',
                                              arguments: arguments, actor_id: assistant.id)
      expect(status).to eq(:reserved)
      session.finish_operation(key, result, outcome: outcome)
      key
    end

    def next_version(version, arguments: { slot_id: 9 })
      store_part(version)
      session.reserve_operation(scope: "part:synthetic-part:v#{version}", tool: 'create_appointment', arguments: arguments,
                                actor_id: assistant.id)
    end

    it 'answers the same call of a later version with the stored result when the earlier version did it' do
      finish_version(1, { success: true, data: { appointment_id: 77 } })

      status, receipt = next_version(2)

      expect(status).to eq(:existing)
      expect(receipt).to include('status' => 'finished', 'outcome' => 'success')
      expect(receipt.dig('result', 'data', 'appointment_id')).to eq(77)
      expect(session.arguments_match?(receipt, { slot_id: 9 })).to be(true)
    end

    it 'blocks another call of the same tool in a later version when the earlier version did it' do
      finish_version(1, { success: true, data: { appointment_id: 77 } })

      status, receipt = next_version(2, arguments: { slot_id: 10 })

      expect(status).to eq(:existing)
      expect(receipt).to include('status' => 'blocked', 'reason' => 'mutation_retry_blocked')
    end

    it 'blocks a later version when the outcome of the earlier one is unknown, or was recorded by an older release without one' do
      finish_version(1, { success: false, error: 'Provider did not answer', retryable: false })

      expect(next_version(2).last).to include('status' => 'blocked')

      session.change { |data| data['operations'].each_value { |operation| operation.delete('outcome') } }

      expect(next_version(2).last).to include('status' => 'blocked')
    end

    it 'lets a later version try again when the earlier one changed nothing' do
      finish_version(1, { success: false, error: 'Slot is taken', audit: { mutation_executed: false } })

      expect(next_version(2).first).to eq(:reserved)
    end

    it 'looks past a version that changed nothing to the one that did' do
      finish_version(1, { success: true, data: { appointment_id: 77 } })
      second = Digest::SHA256.hexdigest(JSON.generate(['part:synthetic-part:v2', 'create_appointment']))
      session.change do |data|
        data['operations'][second] = { 'status' => 'finished', 'outcome' => 'not_executed', 'scope' => 'part:synthetic-part:v2',
                                       'arguments_digest' => 'other', 'actor_id' => assistant.id }
      end

      expect(next_version(3, arguments: { slot_id: 9 }).first).to eq(:existing)
      expect(next_version(3, arguments: { slot_id: 11 }).last).to include('status' => 'blocked')
    end

    it 'keeps the receipts of every version of a part that is still registered, when another action is reserved' do
      key = finish_version(1, { success: true, data: { appointment_id: 77 } })
      store_part(2)

      status, = session.reserve_operation(scope: 'part:synthetic-part:v2', tool: 'cancel_appointment', arguments: { id: 1 }, actor_id: assistant.id)

      expect(status).to eq(:reserved)
      expect(stored_operations[key]).to include('status' => 'finished', 'outcome' => 'success')
    end

    it 'still forgets the receipts of a request that has no registered part' do
      _, old_key = reserve(scope: 'request:old')
      session.finish_operation(old_key, { success: true })

      reserve(scope: 'request:new', tool: 'cancel_appointment')

      expect(stored_operations).not_to have_key(old_key)
    end
  end

  describe 'the part of a council, run by an agent that does not hold the conversation' do
    let(:specialist) { create(:captain_assistant, account: account) }

    before do
      session.update_routing(actor_id: specialist.id)
      store_part(1)
    end

    def reserve_part(actor_id: assistant.id, peer_part: false, scope: 'part:synthetic-part:v1')
      session.reserve_operation(scope: scope, tool: 'create_appointment', arguments: { slot_id: 9 }, actor_id: actor_id, peer_part: peer_part)
    end

    it 'accepts the executor of the part as a peer, though another agent is the current one of the conversation' do
      expect(reserve_part(peer_part: true).first).to eq(:reserved)
    end

    it 'refuses it without the peer flag, as before' do
      expect { reserve_part }.to raise_error(Captain::Conversation::ControlGenerationStaleError, /Request part is no longer executable/)
    end

    it 'still refuses an actor that is not the executor of the part, a version that is not current and a cancelled part' do
      expect { reserve_part(actor_id: specialist.id, peer_part: true) }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
      expect { reserve_part(peer_part: true, scope: 'part:synthetic-part:v2') }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
      session.change { |data| data['parts'].first['cancelled'] = true }
      expect { reserve_part(peer_part: true) }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
    end
  end
end
