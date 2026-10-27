require 'rails_helper'

RSpec.describe Captain::Playground::Session do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }

  def session(**)
    described_class.new(account: account, user: user, **)
  end

  after { Current.reset }

  it 'starts with no agent: the router picks the one that answers, and the session knows it after the first turn' do
    first = assistant
    create(:captain_assistant, account: account)

    session.with_lock do |workspace|
      expect(workspace.assistant).to be_nil
      expect(workspace.scope).to have_attributes(kind: :workspace)
      expect(workspace.context_reference).to include(assistant_id: nil)
      expect(workspace.context_reference).not_to have_key(:entry_assistant_id)
      workspace.activate_agent!(first)
      expect(workspace.assistant).to eq(first)
      expect(workspace.context_reference).to include(assistant_id: first.id)
    end
  end

  it 'persists synthetic JSON and server history without creating any business records' do
    assistant
    user
    counts = [Contact, Conversation, Message, Scheduling::Appointment, Crm::Deal].map(&:count)
    id = nil
    session.with_lock do |workspace|
      id = workspace.id
      workspace.scenario.apply({ contact: { name: 'Changed caller' }, patients: [{ name: 'Second synthetic patient', identifier: '' }] },
                               mode: 'workspace')
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

  it 'rejects session references belonging to a different operator or account and rejects legacy Live' do
    id = nil
    session.with_lock { |workspace| id = workspace.id }
    other_user = create(:user, account: account)
    other_account = create(:account)
    expect { session(user: other_user, session_id: id).with_lock { true } }.to raise_error(Captain::Playground::SessionStore::Stale)
    expect { session(account: other_account, session_id: id).with_lock { true } }.to raise_error(Captain::Playground::SessionStore::Stale)
    expect { session(mode: 'live', session_id: id) }.to raise_error(ArgumentError, /Legacy Live/)
  end

  it 'defaults writes off, requires reads, and revokes the generation immediately while the model turn lock is held' do
    session.with_lock do |workspace|
      expect(workspace.payload).to include(mode: 'workspace', real_data_read: false, real_data_write: false, delivery_enabled: false)
      expect(workspace.set_permissions!(read: false, write: true)).to include('read' => false, 'write' => false)
      permitted = workspace.set_permissions!(read: true, write: true)
      workspace.data['action_previews'] << { 'id' => SecureRandom.uuid, 'status' => 'pending', 'generation' => permitted['generation'],
                                             'expires_at' => 10.minutes.from_now.to_i, 'binding' => workspace.context_reference.stringify_keys }
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
    store = Captain::Playground::SessionStore.new(account: account, user: user)
    expect(store.instance_variable_get(:@key)).to eq("captain:playground:v3:#{account.id}:#{user.id}")
    store.with_lock { expect { store.with_lock { true } }.to raise_error(Captain::Playground::SessionStore::Busy) }
    expect { store.write('value' => 'x' * Captain::Playground::SessionStore::MAX_BYTES) }.to raise_error(ArgumentError)
    expect(Redis::Alfred).to receive(:set).with(anything, anything, ex: Captain::Playground::SessionStore::TTL).and_call_original
    store.write('id' => SecureRandom.uuid)
  end

  it 'persists the active agent in the session and restores it before confirmation' do
    destination = create(:captain_assistant, account: account)
    inbox = create(:inbox, account: account)
    id = nil
    session.with_lock(inbox_id: inbox.id) do |workspace|
      id = workspace.id
      workspace.activate_agent!(destination)
      expect(workspace.assistant).to eq(destination)
      expect(workspace.context_reference).to include(assistant_id: destination.id)
      expect(workspace.deep_dup).to equal(workspace)
    end

    session(session_id: id).with_lock do |workspace|
      expect(workspace.assistant.id).to eq(destination.id)
      expect(workspace.validate_active_agent!.id).to eq(destination.id)
    end
  end

  it 'rejects a disabled, foreign or internal acting agent using the current graph' do
    destination = create(:captain_assistant, account: account)
    inbox = create(:inbox, account: account)
    session.with_lock(inbox_id: inbox.id) do |workspace|
      expect { workspace.activate_agent!(create(:captain_assistant)) }.to raise_error(Pundit::NotAuthorizedError)
      workspace.activate_agent!(destination)
      destination.update!(active: false)
      expect { workspace.validate_active_agent! }.to raise_error(Pundit::NotAuthorizedError, /disabled or not an agent of this Playground channel/)
      destination.update!(active: true)
      destination.update!(usage_mode: 'internal_assistant')
      expect { workspace.validate_active_agent! }.to raise_error(Pundit::NotAuthorizedError, /disabled or not an agent of this Playground channel/)
    end
  end

  describe 'the owner of a council part, which is not the active agent' do
    let(:peer) { create(:captain_assistant, account: account) }
    let(:inbox) { create(:inbox, account: account) }

    # The agents of the chosen channel are the peers; the session works on a channel, with one agent active.
    def routed_session
      session.with_lock(inbox_id: inbox.id) do |workspace|
        workspace.activate_agent!(assistant)
        yield workspace
      end
    end

    def state_for(workspace, actor)
      { playground: workspace.context_reference, source: 'playground', assistant_id: actor.id }
    end

    it 'cannot pass the checks of the session as itself: the session knows its active agent only' do
      routed_session do |workspace|
        expect { workspace.assert_context!(state_for(workspace, peer)) }.to raise_error(ArgumentError, /acting agent changed/)
      end
    end

    it 'passes them through a view of the session that acts as the owner, while the session keeps its active agent and its references' do
      routed_session do |workspace|
        view = workspace.acting_as(peer.id)

        expect(view.assistant).to eq(peer)
        expect(view.context_reference).to eq(workspace.context_reference)
        expect(view.context_reference[:assistant_id]).to eq(assistant.id)
        expect { view.assert_context!(state_for(workspace, peer)) }.not_to raise_error
        expect(view.validate_active_agent!).to eq(peer)
        expect(workspace.assistant).to eq(assistant)
        expect(view.data).to equal(workspace.data)
        expect(view.store).to equal(workspace.store)
      end
    end

    it 'still refuses an agent that is foreign, disabled, or not an agent of the channel' do
      routed_session do |workspace|
        expect { workspace.acting_as(create(:captain_assistant).id) }.to raise_error(Pundit::NotAuthorizedError)
        internal = create(:captain_assistant, account: account, usage_mode: 'internal_assistant')
        expect { workspace.acting_as(internal.id) }.to raise_error(Pundit::NotAuthorizedError, /not an agent of this Playground channel/)
        view = workspace.acting_as(peer.id)
        peer.update!(active: false)
        expect { view.validate_active_agent! }.to raise_error(Pundit::NotAuthorizedError, /disabled or not an agent of this Playground channel/)
      end
    end

    it 'does not let the view act for the run of another session' do
      routed_session do |workspace|
        view = workspace.acting_as(peer.id)
        foreign = state_for(workspace, peer).merge(playground: workspace.context_reference.merge(session_id: SecureRandom.uuid))

        expect { view.assert_context!(foreign) }.to raise_error(ArgumentError, /does not match the server session/)
      end
    end
  end

  it 'uses a selected real inbox for Playground routing when one is recorded' do
    inbox = create(:inbox, account: account)
    member = create(:captain_assistant, account: account)
    session.with_lock do |workspace|
      workspace.data['inbox_id'] = inbox.id
      expect(workspace.routing_inbox).to eq(inbox)
      # A text channel exposes every enabled external agent of the workspace.
      expect(workspace.activate_agent!(member)).to eq(member)
    end
  end

  it 'reaches other active external agents of the workspace even without a chosen channel' do
    destination = create(:captain_assistant, account: account)
    session.with_lock do |workspace|
      expect(workspace.routing_inbox).to be_nil
      expect(workspace.activate_agent!(destination)).to eq(destination)
      expect(workspace.assistant).to eq(destination)
    end
  end

  it 'routes to every enabled external agent on a chosen text channel, and to the agent of the number on a voice channel' do
    inbox = create(:inbox, account: account)
    assistant
    other = create(:captain_assistant, account: account)
    voice_inbox = create_voice_inbox(account)
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: other)

    session.with_lock(inbox_id: inbox.id) do |workspace|
      expect(workspace.routing_inbox).to eq(inbox)
      expect(workspace.graph.agents.map(&:id)).to contain_exactly(assistant.id, other.id)
      expect(workspace.activate_agent!(assistant)).to eq(assistant)
      expect(workspace.activate_agent!(other)).to eq(other)
    end
    session.with_lock(inbox_id: voice_inbox.id) do |workspace|
      expect(workspace.graph.agents).to eq([other])
      expect { workspace.activate_agent!(assistant) }.to raise_error(Pundit::NotAuthorizedError, /not an agent of this Playground channel/)
    end
  end

  it 'keeps the chosen channel in the session and starts again with no agent when another channel is chosen' do
    inbox = create(:inbox, account: account)
    other_inbox = create(:inbox, account: account)
    destination = create(:captain_assistant, account: account)
    id = nil
    session.with_lock(inbox_id: inbox.id) do |workspace|
      id = workspace.id
      workspace.activate_agent!(destination)
    end

    session(session_id: id).with_lock do |workspace|
      expect(workspace.routing_inbox).to eq(inbox)
      expect(workspace.assistant).to eq(destination)
    end
    session(session_id: id).with_lock(inbox_id: other_inbox.id) do |workspace|
      expect(workspace.routing_inbox).to eq(other_inbox)
      expect(workspace.assistant).to be_nil
      expect(workspace.data['active_assistant_id']).to be_nil
    end
  end

  it 'drops the durable agent session of the old grid so a peer present in both channels does not keep the turn' do
    inbox = create(:inbox, account: account)
    other_inbox = create(:inbox, account: account)
    peer = create(:captain_assistant, account: account)
    id = nil
    session.with_lock(inbox_id: inbox.id) do |workspace|
      id = workspace.id
      workspace.activate_agent!(peer)
      Captain::Conversation::AgentSession.new(playground: workspace).update_routing(actor_id: peer.id)
      expect(workspace.data[Captain::Conversation::AgentSession::ATTRIBUTE]).to include('current_assistant_id' => peer.id)
    end

    session(session_id: id).with_lock(inbox_id: other_inbox.id) do |workspace|
      expect(workspace.data).not_to have_key(Captain::Conversation::AgentSession::ATTRIBUTE)
      context = { state: { account_id: account.id, assistant_id: assistant.id }, conversation_history: [] }

      Captain::AgentRunContext.new(scope: workspace.scope, playground: workspace).prepare(context)

      expect(context[:routing_current_agent_id]).to be_nil
      expect(context[:routing_trail]).to eq([])
    end
  end

  it 'keeps the agent session while the same channel is sent again and revokes pending previews on a switch' do
    inbox = create(:inbox, account: account)
    other_inbox = create(:inbox, account: account)
    id = nil
    session.with_lock(inbox_id: inbox.id) do |workspace|
      id = workspace.id
      workspace.data['action_previews'] = [{ 'id' => 'p1', 'status' => 'pending' }]
      workspace.data[Captain::Conversation::AgentSession::ATTRIBUTE] = { 'marker' => 'kept' }
    end

    session(session_id: id).with_lock(inbox_id: inbox.id) do |workspace|
      expect(workspace.data.dig(Captain::Conversation::AgentSession::ATTRIBUTE, 'marker')).to eq('kept')
      expect(workspace.data['action_previews'].first['status']).to eq('pending')
    end
    session(session_id: id).with_lock(inbox_id: other_inbox.id) do |workspace|
      expect(workspace.data).not_to have_key(Captain::Conversation::AgentSession::ATTRIBUTE)
      expect(workspace.data['action_previews'].first['status']).to eq('revoked')
    end
  end

  it 'rejects a channel of another workspace' do
    foreign_inbox = create(:inbox)

    expect { session.with_lock(inbox_id: foreign_inbox.id) { true } }
      .to raise_error(ArgumentError, /channel is not available/)
  end
end
