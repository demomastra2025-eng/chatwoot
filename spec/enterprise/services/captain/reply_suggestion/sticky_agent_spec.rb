# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::StickyAgent do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:other_conversation) { create(:conversation, account: account, contact: contact) }

  after { described_class.keys_for(conversation).each { |key| Redis::Alfred.delete(key) } }

  it 'keeps the agent of the dialog for 24 hours per conversation' do
    described_class.remember!(conversation, 84)

    expect(described_class.read(conversation)).to eq(84)
    key = described_class.keys_for(conversation).first
    expect($alfred.with { |connection| connection.ttl(key) }).to be_within(5).of(24.hours.to_i) # rubocop:disable Style/GlobalVars
    expect(described_class.read(other_conversation)).to be_nil
  end

  it 'replaces it with the agent of a later suggestion' do
    described_class.remember!(conversation, 84)
    described_class.remember!(conversation, 119)

    expect(described_class.read(conversation)).to eq(119)
  end

  it 'reads the agent of the person thread when the conversation has none of its own' do
    thread = create(:communication_thread, account: account, contact: contact)
    [conversation, other_conversation].each do |item|
      CommunicationThreadConversation.where(account_id: account.id, conversation_id: item.id).delete_all
      create(:communication_thread_conversation, communication_thread: thread, conversation: item)
    end
    described_class.remember!(conversation.reload, 120)

    expect(described_class.read(other_conversation.reload)).to eq(120)
  ensure
    described_class.keys_for(other_conversation).each { |key| Redis::Alfred.delete(key) }
  end

  it 'stores nothing without a conversation or an agent' do
    expect(described_class.remember!(nil, 84)).to be_nil
    expect(described_class.remember!(conversation, nil)).to be_nil
    expect(described_class.read(conversation)).to be_nil
  end

  describe '.agent_id_of' do
    it 'is the agent of a draft, of a "no reply needed" and of a staff request of the agent itself' do
      expect(described_class.agent_id_of(outcome: 'draft', agent: { 'id' => 84 })).to eq(84)
      expect(described_class.agent_id_of(outcome: 'no_reply', agent: { 'id' => 119 })).to eq(119)
      expect(described_class.agent_id_of(outcome: 'human_needed', reason_source: 'agent', agent: { 'id' => 120 })).to eq(120)
    end

    it 'is nobody for a staff request of the router, a safety stop, a failure or a cancel' do
      expect(described_class.agent_id_of(outcome: 'human_needed', reason_source: 'router', agent: nil)).to be_nil
      expect(described_class.agent_id_of(outcome: 'human_needed', reason_source: 'safety', agent: { 'id' => 84 })).to be_nil
      expect(described_class.agent_id_of(outcome: 'failed', reason_code: 'router_unavailable')).to be_nil
      expect(described_class.agent_id_of(outcome: 'cancelled')).to be_nil
    end
  end
end
