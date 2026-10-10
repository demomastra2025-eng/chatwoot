require 'rails_helper'

RSpec.describe Captain::Playground::ReplyDelivery do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:channel_sms, account: account).inbox }

  after { Current.reset }

  def session(mode)
    Captain::Playground::Session.new(assistant: assistant, account: account, user: user, mode: mode)
  end

  it 'returns Playground-only status without building any message in Trial' do
    expect(Messages::MessageBuilder).not_to receive(:new)
    session('trial').with_lock do |trial|
      expect(described_class.new(trial).perform(response: 'Trial reply')).to include(status: 'playground_only', delivered: false)
    end
  end

  it 'returns Playground-only status for Live when external delivery is disabled' do
    expect(Messages::MessageBuilder).not_to receive(:new)
    session('live').with_lock(inbox_id: inbox.id) do |live|
      expect(described_class.new(live).perform(response: 'Live reply')).to include(status: 'playground_only', delivered: false)
    end
  end

  it 'creates and queues a native message only for the explicitly controlled test caller' do
    session('live').with_lock(inbox_id: inbox.id, delivery_enabled: true, delivery_target: '+77015551234') do |live|
      result = nil
      expect do
        result = described_class.new(live).perform(response: 'Controlled reply')
      end.to have_enqueued_job(SendReplyJob)
      expect(result).to include(enabled: true, status: 'queued', delivered: false)
      message = account.messages.find(result[:message_id])
      expect(message.conversation_id).to eq(live.conversation.id)
      expect(message.sender).to eq(assistant)
      expect(message.additional_attributes[Outbound::PlaygroundDeliveryPolicy::ATTRIBUTE_KEY]).to eq(live.run_policy)
    end
  end

  it 'reports a blocked reply after permission is revoked without claiming delivery success' do
    session('live').with_lock(inbox_id: inbox.id, delivery_enabled: true, delivery_target: '+77015551234') do |live|
      account.account_users.find_by!(user_id: user.id).update!(role: :agent)
      result = described_class.new(live).perform(response: 'Revoked permission')
      expect(result).to include(enabled: true, status: 'blocked', delivered: false)
      expect(live.conversation.messages.where(content: 'Revoked permission')).not_to exist
    end
  end

  it 'blocks an opted-in fresh reply when it inherits disabled or invalid causal context' do
    session('live').with_lock(inbox_id: inbox.id, delivery_enabled: true, delivery_target: '+77015551234') do |live|
      disabled = Outbound::PlaygroundDeliveryPolicy.issue(
        Outbound::PlaygroundDeliveryPolicy.verified(live.run_policy).merge(run_id: SecureRandom.uuid, delivery_enabled: false)
      )
      [disabled, false, {}].each do |inherited|
        Outbound::PlaygroundDeliveryPolicy.with(inherited) do
          result = nil
          expect { result = described_class.new(live).perform(response: 'Nested blocked reply') }.not_to have_enqueued_job(SendReplyJob)
          expect(result).to include(enabled: true, status: 'blocked', delivered: false)
          expect(Current.playground_run_policy).to eq(inherited)
        end
      end
      expect(live.conversation.messages.where(content: 'Nested blocked reply')).not_to exist
    end
  end
end
