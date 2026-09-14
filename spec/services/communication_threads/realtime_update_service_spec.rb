# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::RealtimeUpdateService do
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:participant) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account) }
  let!(:first_conversation) { create(:conversation, account: account, contact: contact) }
  let(:second_conversation) { create(:conversation, account: account, contact: contact) }
  let(:communication_thread) { first_conversation.reload.communication_thread }
  let(:links) do
    second_conversation
    communication_thread.communication_thread_conversations.to_a
  end
  let(:service) do
    described_class.new(
      communication_thread_id: communication_thread.id,
      source_conversation_id: first_conversation.id,
      source_event: 'message.created'
    )
  end

  it 'exposes every linked channel to a canonical participant' do
    policy = instance_double(CommunicationThreadPolicy, show?: false)

    visible_links = service.send(:recipient_visible_links, participant, links, [participant.id], policy)

    expect(visible_links).to match_array(links)
    expect(policy).not_to have_received(:show?)
  end

  it 'suppresses realtime links when canonical thread policy denies access' do
    policy = instance_double(CommunicationThreadPolicy, show?: false)

    visible_links = service.send(:recipient_visible_links, participant, links, [], policy)

    expect(visible_links).to be_empty
  end

  it 'sends a final revocation payload to an explicitly targeted removed participant' do
    targeted_service = described_class.new(
      communication_thread_id: communication_thread.id,
      source_conversation_id: first_conversation.id,
      source_event: 'participant.removed',
      recipient_user_ids: [participant.id]
    )
    policy = instance_double(CommunicationThreadPolicy, show?: false)

    visible_links = targeted_service.send(:recipient_visible_links, participant, links, [], policy)

    expect(visible_links).to match_array(links)
    expect(policy).not_to have_received(:show?)
  end
end
