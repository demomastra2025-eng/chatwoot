require 'rails_helper'

RSpec.describe Telephony::OperatorActivity do
  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, name: 'Aigerim Operator', display_name: 'Aigerim') }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  def build_session(overrides = {})
    create(
      :telephony_call_session,
      {
        account: account,
        conversation: conversation,
        contact: conversation.contact,
        inbox: inbox,
        direction: 'outbound',
        status: 'ringing',
        from_number: '+77011112233',
        to_number: '+77022223344',
        started_at: 10.seconds.ago,
        metadata: { 'metadata' => { 'chatwoot_user_id' => operator.id } }
      }.merge(overrides)
    )
  end

  describe '#payload' do
    it 'names the operator who started an outbound call that is ringing' do
      session = build_session

      expect(described_class.new(session).payload).to eq(
        account_id: account.id,
        call_id: session.external_call_ref,
        conversation_id: conversation.display_id,
        operator_user_id: operator.id,
        operator_name: 'Aigerim',
        state: 'calling'
      )
    end

    it 'falls back to the full name when the operator has no display name' do
      operator.update_column(:display_name, nil) # rubocop:disable Rails/SkipsModelValidations

      expect(described_class.new(build_session).payload).to include(operator_name: 'Aigerim Operator')
    end

    it 'carries no phone number or contact data' do
      payload = described_class.new(build_session).payload

      expect(payload.to_json).not_to include('+7701', '+7702')
      expect(payload.keys).to contain_exactly(:account_id, :call_id, :conversation_id, :operator_user_id, :operator_name, :state)
    end

    %w[created ringing connecting].each do |status|
      it "is calling while an outbound call is #{status}" do
        expect(described_class.new(build_session(status: status)).state).to eq('calling')
      end
    end

    it 'is talking once the call is answered' do
      session = build_session(status: 'in_progress', answered_at: 3.seconds.ago)

      expect(described_class.new(session).payload).to include(state: 'talking', operator_user_id: operator.id)
    end

    %w[completed no_answer busy cancelled rejected failed missed].each do |status|
      it "is ended when the call is #{status}" do
        expect(described_class.new(build_session(status: status)).payload).to include(state: 'ended')
      end
    end

    it 'does not announce an inbound call that is still ringing' do
      session = build_session(direction: 'inbound', metadata: { 'operator_claim' => { 'user_id' => operator.id } })

      expect(described_class.new(session).payload).to be_nil
    end

    it 'names the operator who took an inbound call once it is in progress' do
      session = build_session(
        direction: 'inbound',
        status: 'in_progress',
        metadata: { 'operator_claim' => { 'user_id' => operator.id, 'user_name' => 'Somebody Else' } }
      )

      expect(described_class.new(session).payload).to include(state: 'talking', operator_user_id: operator.id, operator_name: 'Aigerim')
    end

    it 'reads the operator of an outbound call from the routed candidates when the starter is not recorded' do
      session = build_session(metadata: { 'metadata' => { 'operator_candidate_user_ids' => [operator.id] } })

      expect(described_class.new(session).payload).to include(operator_user_id: operator.id)
    end

    it 'says nothing when no operator is known' do
      expect(described_class.new(build_session(metadata: {})).payload).to be_nil
    end

    it 'never resolves an operator from another account' do
      foreign_user = create(:user, account: create(:account))
      session = build_session(metadata: { 'metadata' => { 'chatwoot_user_id' => foreign_user.id } })

      expect(described_class.new(session).payload).to be_nil
    end

    it 'says nothing for a call without a conversation' do
      session = build_session
      session.update_column(:conversation_id, nil) # rubocop:disable Rails/SkipsModelValidations

      expect(described_class.new(session.reload).payload).to be_nil
    end

    it 'adds the communication thread when the account uses threads' do
      account.enable_features!('communication_threads')
      thread = conversation.refresh_communication_thread!

      expect(described_class.new(build_session.reload).payload).to include(communication_thread_id: thread.display_id)
    end
  end

  describe '#live_payload' do
    it 'drops a ringing line that is older than any real outbound call' do
      session = build_session(started_at: 10.minutes.ago)

      expect(described_class.new(session).live_payload).to be_nil
    end

    it 'keeps a recent ringing line' do
      expect(described_class.new(build_session).live_payload).to include(state: 'calling')
    end

    it 'drops a talking line that outlived the longest allowed call' do
      session = build_session(status: 'in_progress', answered_at: 6.hours.ago)

      expect(described_class.new(session).live_payload).to be_nil
    end

    it 'keeps a talking line of a long but allowed call' do
      session = build_session(status: 'in_progress', answered_at: 2.hours.ago)

      expect(described_class.new(session).live_payload).to include(state: 'talking')
    end

    it 'never returns an ended call' do
      expect(described_class.new(build_session(status: 'completed')).live_payload).to be_nil
    end
  end
end
