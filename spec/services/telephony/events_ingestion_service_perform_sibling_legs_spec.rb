require 'rails_helper'

# Three operator browsers report their own leg of one Beeline call. When one
# operator takes it, the other two legs are over for their operators at once.
RSpec.describe Telephony::EventsIngestionService, '#perform for an answered Beeline call with sibling legs' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:number_binding) { create(:telephony_number_binding, account: account, inbox: inbox) }
  let(:users) { Array.new(3) { create(:user, account: account, role: :agent) } }
  let(:root_ref) { 'beeline:janus:101:call-id-a@sbc.example.test' }
  let!(:bindings) do
    users.each_with_index.map do |user, index|
      create(:telephony_agent_binding, :registered, account: account, user: user,
                                                    agent_ref: "agent-100#{index}", agent_aor: "sip:100#{index}@voice.example")
    end
  end
  let!(:legs) do
    [root_ref, 'beeline:janus:102:call-id-b@sbc.example.test', 'beeline:janus:103:call-id-c@sbc.example.test']
      .each_with_index.map { |ref, index| create_leg(ref, users[index]) }
  end
  let(:winner_user) { users.first }
  let(:winner_leg) { legs.first }
  let(:sibling_legs) { legs.drop(1) }

  def create_leg(ref, user)
    group = { 'logical_call_key' => 'janus-inbound:one-call', 'call_group_key' => 'janus-inbound:one-call', 'logical_call_group_ref' => root_ref }
    candidates = { 'operator_candidate_user_ids' => [user.id], 'operator_candidate_binding_ids' => bindings.map(&:id) }
    create(
      :telephony_call_session,
      account: account, conversation: conversation, contact: conversation.contact, inbox: inbox,
      number_binding: number_binding, provider: 'beeline', direction: 'inbound', status: 'ringing',
      external_call_ref: ref, from_number: '+70000000001', to_number: '+70000000099',
      metadata: { 'metadata' => { 'route_action' => 'operator', 'target_user_id' => user.id }.merge(group, candidates) }
    )
  end

  before do
    users.each { |user| create(:inbox_member, inbox: inbox, user: user) }
  end

  def claim!
    Telephony::OperatorCallClaimService.new(account: account, user: winner_user, call_ref: winner_leg.external_call_ref).perform
  end

  def sibling_voice_messages
    conversation.messages.voice_calls.where(source_id: sibling_legs.map(&:voice_call_source_id))
  end

  def expect_closed_for_other_operator(leg)
    expect(leg.reload).to have_attributes(status: 'no_answer', end_reason: 'answered_by_other_operator')
  end

  describe 'when an operator claims one leg' do
    it 'closes the other legs right away and still tells every candidate about the claim' do
      broadcasts = []
      allow(ActionCable.server).to receive(:broadcast) { |token, event| broadcasts << [token, event] }

      claim!

      expect(winner_leg.reload.status).to eq('connecting')
      sibling_legs.each { |leg| expect_closed_for_other_operator(leg) }
      claimed_tokens = broadcasts.select { |_token, event| event[:event] == 'voice_call.claimed' }.map(&:first)
      expect(claimed_tokens).to include(users[1].pubsub_token, users[2].pubsub_token)
    end

    it 'does not turn a leg closed at claim time, before the answer, into a missed call' do
      claim!

      expect(sibling_voice_messages).to be_empty
      expect(conversation.reload.additional_attributes['call_status']).not_to eq('no_answer')
    end

    it 'does not fail the claim when closing the other legs fails' do
      allow(described_class).to receive(:new).and_call_original
      allow(described_class).to receive(:new)
        .with(hash_including(payload: hash_including(end_reason: 'answered_by_other_operator')))
        .and_raise(StandardError, 'simulated failure')

      expect(claim!).to include(claimed: true)
      expect(sibling_legs.map { |leg| leg.reload.status }).to all(eq('ringing'))
    end
  end

  describe 'when the answered event reaches the ingestion service' do
    let(:answered_payload) do
      {
        account_id: account.id, call_ref: winner_leg.external_call_ref, provider: 'beeline', event: 'operator_answered',
        event_type: 'operator_answered', event_key: 'webphone:operator_answered:winner', direction: 'inbound',
        answered_by: "user:#{winner_user.id}", metadata: { source: 'browser_janus_sip', route_action: 'operator' }
      }
    end

    it 'closes the sibling legs once, however often the event is replayed' do
      2.times { described_class.new(payload: answered_payload).perform }

      expect(winner_leg.reload.status).to eq('in_progress')
      sibling_legs.each { |leg| expect_closed_for_other_operator(leg) }
      expect(account.telephony_events.where(event_key: "answered_by_other_operator:#{sibling_legs.first.external_call_ref}").count).to eq(1)
    end

    it 'leaves no missed call behind and keeps the answered leg as it is' do
      described_class.new(payload: answered_payload).perform

      expect(sibling_voice_messages).to be_empty
      expect(winner_leg.reload).to have_attributes(status: 'in_progress', end_reason: nil, ended_at: nil)
    end

    it 'tells the operators of the other legs that their call is gone' do
      allow(ActionCable.server).to receive(:broadcast)

      described_class.new(payload: answered_payload).perform

      [[users[1], sibling_legs.first], [users[2], sibling_legs.last]].each do |user, leg|
        expect(ActionCable.server).to have_received(:broadcast).with(
          user.pubsub_token,
          hash_including(event: 'voice_call.status_changed', data: hash_including(callSid: leg.external_call_ref, status: 'no_answer'))
        )
      end
    end

    it 'does not close the legs of another provider' do
      legs.each { |leg| leg.update!(provider: 'sipuni') }

      described_class.new(payload: answered_payload.merge(provider: 'sipuni')).perform

      expect(sibling_legs.map { |leg| leg.reload.status }).to all(eq('ringing'))
    end
  end
end
