require 'rails_helper'

RSpec.describe Telephony::OperatorActivityBroadcaster do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:operator) { create(:user, account: account, role: :agent, name: 'Aigerim Operator', display_name: 'Aigerim') }
  let(:colleague) { create(:user, account: account, role: :agent) }
  let(:outsider) { create(:user, account: account, role: :agent) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: inbox,
      direction: 'outbound',
      status: 'ringing',
      started_at: 5.seconds.ago,
      metadata: { 'metadata' => { 'chatwoot_user_id' => operator.id } }
    )
  end
  let(:broadcasts) { [] }

  before do
    [operator, colleague].each { |user| create(:inbox_member, inbox: inbox, user: user) }
    administrator
    outsider
    allow(ActionCable.server).to receive(:broadcast) { |token, event| broadcasts << [token, event] }
  end

  it 'tells the colleagues that can see the conversation, and nobody else' do
    foreign_user = create(:user, account: create(:account), role: :agent)

    described_class.new(call_session: call_session).perform

    expect(broadcasts.map(&:first)).to contain_exactly(colleague.pubsub_token, administrator.pubsub_token)
    expect(broadcasts.map(&:first)).not_to include(operator.pubsub_token, outsider.pubsub_token, foreign_user.pubsub_token)
  end

  context 'when a member has a custom role that restricts the conversations he may see' do
    let(:restricted) { create(:user, account: account, role: :agent) }
    let(:custom_role) { create(:custom_role, account: account, permissions: ['conversation_participating_manage']) }

    before do
      create(:inbox_member, inbox: inbox, user: restricted)
      restricted.account_users.find_by(account: account).update!(role: :agent, custom_role: custom_role)
    end

    it 'does not tell a member who is neither assignee nor participant of the conversation' do
      described_class.new(call_session: call_session).perform

      expect(broadcasts.map(&:first)).to contain_exactly(colleague.pubsub_token, administrator.pubsub_token)
      expect(broadcasts.map(&:first)).not_to include(restricted.pubsub_token)
    end

    it 'tells the member once he is the assignee of the conversation' do
      conversation.update!(assignee: restricted)

      described_class.new(call_session: call_session).perform

      expect(broadcasts.map(&:first)).to include(restricted.pubsub_token)
    end

    it 'tells the member once he is a participant of the conversation' do
      create(:conversation_participant, conversation: conversation, user: restricted, account: account)

      described_class.new(call_session: call_session).perform

      expect(broadcasts.map(&:first)).to include(restricted.pubsub_token)
    end
  end

  it 'sends the operator name, the state and the conversation, without any phone number' do
    described_class.new(call_session: call_session).perform

    event = broadcasts.first.last
    expect(event[:event]).to eq('voice_call.operator_activity')
    expect(event[:data]).to eq(
      account_id: account.id,
      call_id: call_session.external_call_ref,
      conversation_id: conversation.display_id,
      operator_user_id: operator.id,
      operator_name: 'Aigerim',
      state: 'calling'
    )
    expect(event.to_json).not_to include(call_session.to_number.to_s, call_session.from_number.to_s)
  end

  it 'announces that the call is being talked once it is answered and that it ended' do
    call_session.update!(status: 'in_progress', answered_at: Time.current)
    described_class.new(call_session: call_session).perform
    call_session.update!(status: 'completed', ended_at: Time.current)
    described_class.new(call_session: call_session).perform

    expect(broadcasts.map { |_token, event| event[:data][:state] }.uniq).to eq(%w[talking ended])
  end

  it 'stays silent when the operator of the call is unknown' do
    call_session.update!(metadata: {})

    described_class.new(call_session: call_session).perform

    expect(broadcasts).to be_empty
  end

  it 'does not reach members of an inbox that belongs to another account' do
    foreign_inbox = create(:inbox, account: create(:account))
    foreign_member = create(:user, account: foreign_inbox.account, role: :agent)
    create(:inbox_member, inbox: foreign_inbox, user: foreign_member)
    call_session.update_column(:inbox_id, foreign_inbox.id) # rubocop:disable Rails/SkipsModelValidations

    described_class.new(call_session: call_session.reload).perform

    expect(broadcasts).to be_empty
  end

  it 'never breaks the call flow when the broadcast fails' do
    allow(ActionCable.server).to receive(:broadcast).and_raise(StandardError, 'cable down')

    expect { described_class.new(call_session: call_session).perform }.not_to raise_error
  end
end
