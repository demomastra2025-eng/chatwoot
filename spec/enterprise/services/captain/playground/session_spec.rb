require 'rails_helper'

RSpec.describe Captain::Playground::Session do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }

  def session(**)
    described_class.new(assistant: assistant, account: account, user: user, **)
  end

  after { Current.reset }

  it 'keeps Trial state and history in a server session without creating business records' do
    id = nil
    expect do
      session.with_lock do |trial|
        id = trial.id
        trial.scenario.apply({ contact: { name: 'Изменённое имя' } }, mode: 'trial')
        trial.record_turn('Hello', { 'response' => 'Reply' })
      end
    end.not_to change(Contact, :count)

    session(session_id: id).with_lock do |trial|
      expect(trial.scenario.contact['name']).to eq('Изменённое имя')
      expect(trial.data['history'].map { |message| message['content'] }).to eq(%w[Hello Reply])
      expect(trial.payload[:scenario][:patient]['phone_number']).not_to eq(trial.scenario.contact['phone_number'])
    end
  end

  it 'rejects session references from another user, account, assistant, or mode' do
    id = nil
    session.with_lock { |trial| id = trial.id }
    other_user = create(:user, account: account)
    other_account = create(:account)
    other_assistant = create(:captain_assistant, account: account)
    expect { session(user: other_user, session_id: id).with_lock { |trial| trial.id } }.to raise_error(Captain::Playground::SessionStore::Stale)
    expect { session(assistant: other_assistant, session_id: id).with_lock { |trial| trial.id } }.to raise_error(Captain::Playground::SessionStore::Stale)
    expect { session(mode: 'live', session_id: id).with_lock(inbox_id: inbox.id) { |live| live.id } }
      .to raise_error(Captain::Playground::SessionStore::Stale)
    expect { session(account: other_account, session_id: id) }.to raise_error(ArgumentError)
  end

  it 'resets the Trial scenario and history and invalidates the previous handle' do
    id = nil
    session.with_lock do |trial|
      id = trial.id
      trial.scenario.apply({ contact: { name: 'Changed' } }, mode: 'trial')
      trial.record_turn('Change', { 'response' => 'Changed' })
    end
    session(session_id: id).with_lock(reset: true) do |trial|
      expect(trial.id).not_to eq(id)
      expect(trial.scenario.contact['name']).to eq('Айгуль Садыкова')
      expect(trial.data['history']).to eq([])
    end
    expect { session(session_id: id).with_lock { |trial| trial.id } }.to raise_error(Captain::Playground::SessionStore::Stale)
  end

  it 'persists completed synthetic actions even when a later part of the turn raises' do
    expect do
      session.with_lock do |trial|
        trial.scenario.apply({ contact: { name: 'Saved before timeout' } }, mode: 'trial')
        raise Timeout::Error, 'provider timeout'
      end
    end.to raise_error(Timeout::Error)
    session.with_lock { |trial| expect(trial.scenario.contact['name']).to eq('Saved before timeout') }
  end

  it 'allows an explicit reset after the cached session has expired' do
    session(session_id: SecureRandom.uuid).with_lock(reset: true) { |trial| expect(trial.payload[:mode]).to eq('trial') }
  end

  it 'rejects overlapping turns and keeps a bounded expiring cache entry' do
    store = Captain::Playground::SessionStore.new(account: account, user: user, assistant: assistant, mode: 'trial')
    store.with_lock do
      expect { store.with_lock { true } }.to raise_error(Captain::Playground::SessionStore::Busy)
    end
    expect { store.write('value' => 'x' * Captain::Playground::SessionStore::MAX_BYTES) }.to raise_error(ArgumentError)
    expect(Redis::Alfred).to receive(:set).with(anything, anything, ex: Captain::Playground::SessionStore::TTL).and_call_original
    store.write('id' => SecureRandom.uuid)
  end

  it 'requires an administrator for Live without granting a new agent tool set' do
    regular_user = create(:user, account: account, role: :agent)
    expect { session(user: regular_user, mode: 'live') }.to raise_error(Pundit::NotAuthorizedError)
    original = assistant.config.deep_dup
    session(mode: 'live').with_lock(inbox_id: inbox.id) { |live| expect(live.payload[:delivery_enabled]).to be(false) }
    expect(assistant.reload.config).to eq(original)
  end

  it 'creates only a dedicated actual caller and conversation and never borrows an existing patient identity' do
    original = create(:contact, account: account, name: 'Real patient')
    original_conversation = create(:conversation, account: account, inbox: inbox, contact: original)
    before_counts = [Scheduling::Appointment.count, Crm::Deal.count, Message.count]
    expect do
      session(mode: 'live').with_lock(inbox_id: inbox.id) do |live|
        expect(live.conversation.id).not_to eq(original_conversation.id)
        expect(live.conversation.contact_id).not_to eq(original.id)
        expect(live.conversation.contact_inbox.hmac_verified).to be(false)
        expect(Outbound::PlaygroundDeliveryPolicy.verified(live.run_policy)[:delivery_enabled]).to be(false)
      end
    end.to change(Contact, :count).by(1).and change(Conversation, :count).by(1)
    expect([Scheduling::Appointment.count, Crm::Deal.count, Message.count]).to eq(before_counts)
    expect(original.reload.name).to eq('Real patient')
  end

  it 'keeps only the actual caller profile and no synthetic business catalogues in a Live session' do
    session(mode: 'live').with_lock(inbox_id: inbox.id) do |live|
      expect(live.payload[:scenario].keys).to eq([:contact])
      expect(live.payload[:scenario][:contact]['id']).to eq(live.conversation.contact_id)
      expect(live.scenario.data.values_at('resources', 'services', 'pipelines', 'stages', 'deals', 'appointments')).to all(eq([]))
      expect(live.scenario.data['contacts'].pluck('id')).to eq([live.conversation.contact_id])
      expect(live.payload[:live_warning]).to eq(described_class::LIVE_WARNING)
    end
  end

  it 'rejects synthetic business scenario records and uncontrolled delivery opt-in in Live' do
    expect do
      session(mode: 'live').with_lock(inbox_id: inbox.id, scenario_input: { deal: { title: 'Synthetic deal' } }) { |live| live.id }
    end.to raise_error(ArgumentError, 'Live only accepts the test caller profile')
    expect do
      session(mode: 'live').with_lock(inbox_id: inbox.id, delivery_enabled: true) { |live| live.id }
    end.to raise_error(ArgumentError, 'A controlled test phone number is required')
  end
end
