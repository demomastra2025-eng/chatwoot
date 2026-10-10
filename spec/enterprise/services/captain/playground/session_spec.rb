require 'rails_helper'

RSpec.describe Captain::Playground::Session do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }

  def session(**)
    described_class.new(assistant: assistant, account: account, user: user, **)
  end

  after { Current.reset }

  it 'persists synthetic JSON and server history without creating any business records' do
    assistant
    user
    counts = [Contact, Conversation, Message, Scheduling::Appointment, Crm::Deal].map(&:count)
    id = nil
    session.with_lock do |workspace|
      id = workspace.id
      workspace.scenario.apply({ contact: { name: 'Changed caller' }, patients: [{ name: 'Second synthetic patient', identifier: '' }] }, mode: 'workspace')
      workspace.record_turn('Hello', { 'response' => 'Reply' })
    end
    session(session_id: id).with_lock do |workspace|
      expect(workspace.scenario.contact['name']).to eq('Changed caller')
      expect(workspace.scenario.data['contacts'].size).to eq(3)
      expect(workspace.data['history'].pluck('content')).to eq(%w[Hello Reply])
      expect(workspace.payload.dig(:scenario, :contact, 'id')).to be_negative
      expect(workspace.conversation).to be_nil
    end
    expect([Contact, Conversation, Message, Scheduling::Appointment, Crm::Deal].map(&:count)).to eq(counts)
  end

  it 'rejects session references belonging to a different operator, account or profile and rejects legacy Live' do
    id = nil
    session.with_lock { |workspace| id = workspace.id }
    other_user = create(:user, account: account)
    other_account = create(:account)
    other_assistant = create(:captain_assistant, account: account)
    expect { session(user: other_user, session_id: id).with_lock { true } }.to raise_error(Captain::Playground::SessionStore::Stale)
    expect { session(assistant: other_assistant, session_id: id).with_lock { true } }.to raise_error(Captain::Playground::SessionStore::Stale)
    expect { session(account: other_account, session_id: id) }.to raise_error(ArgumentError)
    expect { session(mode: 'live', session_id: id) }.to raise_error(ArgumentError, /Legacy Live/)
  end

  it 'defaults writes off, requires reads, and revokes the generation immediately while the model turn lock is held' do
    session.with_lock do |workspace|
      expect(workspace.payload).to include(mode: 'workspace', real_data_read: false, real_data_write: false, delivery_enabled: false)
      expect(workspace.set_permissions!(read: false, write: true)).to include('read' => false, 'write' => false)
      permitted = workspace.set_permissions!(read: true, write: true)
      workspace.data['action_previews'] << { 'id' => SecureRandom.uuid, 'status' => 'pending', 'generation' => permitted['generation'],
                                            'expires_at' => 10.minutes.from_now.to_i }
      expect(workspace.payload[:action_previews].size).to eq(1)
      revoker = session(session_id: workspace.id)
      revoked = revoker.set_permissions!(read: false, write: true)
      expect(revoked).to include('read' => false, 'write' => false)
      expect(revoked['generation']).not_to eq(permitted['generation'])
      expect(workspace.write_enabled?).to be(false)
      expect(workspace.payload[:action_previews]).to eq([])
      expect(workspace.conversation).to be_nil
    end
  end

  it 'resets history, scenario and permissions and invalidates the former session handle' do
    id = nil
    session.with_lock do |workspace|
      id = workspace.id
      workspace.set_permissions!(read: true, write: true)
      workspace.scenario.apply({ contact: { name: 'Changed' } }, mode: 'workspace')
      workspace.record_turn('Change', { 'response' => 'Changed' })
    end
    session(session_id: id).with_lock(reset: true) do |workspace|
      expect(workspace.id).not_to eq(id)
      expect(workspace.scenario.contact['name']).to eq('Айгуль Садыкова')
      expect(workspace.data['history']).to eq([])
      expect(workspace.payload).to include(real_data_read: false, real_data_write: false, action_previews: [])
    end
    expect { session(session_id: id).with_lock { true } }.to raise_error(Captain::Playground::SessionStore::Stale)
  end

  it 'preserves completed synthetic edits after a model timeout' do
    expect do
      session.with_lock do |workspace|
        workspace.scenario.apply({ contact: { name: 'Saved before timeout' } }, mode: 'workspace')
        raise Timeout::Error, 'provider timeout'
      end
    end.to raise_error(Timeout::Error)
    session.with_lock { |workspace| expect(workspace.scenario.contact['name']).to eq('Saved before timeout') }
  end

  it 'allows an explicit reset of an expired handle but starts with all real permissions off' do
    session(session_id: SecureRandom.uuid).with_lock(reset: true) do |workspace|
      expect(workspace.payload).to include(mode: 'workspace', real_data_read: false, real_data_write: false)
    end
  end

  it 'rejects overlapping turns and bounds the expiring Redis entry' do
    store = Captain::Playground::SessionStore.new(account: account, user: user, assistant: assistant)
    store.with_lock { expect { store.with_lock { true } }.to raise_error(Captain::Playground::SessionStore::Busy) }
    expect { store.write('value' => 'x' * Captain::Playground::SessionStore::MAX_BYTES) }.to raise_error(ArgumentError)
    expect(Redis::Alfred).to receive(:set).with(anything, anything, ex: Captain::Playground::SessionStore::TTL).and_call_original
    store.write('id' => SecureRandom.uuid)
  end
end
