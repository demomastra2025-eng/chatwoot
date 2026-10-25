# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::StickyAgent do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:other_conversation) { create(:conversation, account: account, contact: contact) }

  def ttl(key)
    $alfred.with { |connection| connection.ttl(key) } # rubocop:disable Style/GlobalVars
  end

  def share_thread(*conversations)
    thread = create(:communication_thread, account: account, contact: contact)
    conversations.each do |item|
      CommunicationThreadConversation.where(account_id: account.id, conversation_id: item.id).delete_all
      create(:communication_thread_conversation, communication_thread: thread, conversation: item)
    end
    conversations.map(&:reload)
  end

  after do
    described_class.clear!(conversation)
    described_class.clear!(other_conversation)
  end

  it 'keeps a confirmed agent for 24 hours and a provisional one for the life of the request, per conversation' do
    described_class.confirm!(conversation, 84, request_id: 'r-1')
    expect(described_class.read(conversation)).to eq(84)
    expect(ttl(described_class.keys_for(conversation, kinds: %w[confirmed]).first)).to be_within(5).of(24.hours.to_i)

    described_class.remember_provisional!(conversation, 119, request_id: 'r-2')
    expect(described_class.read(conversation)).to eq(119)
    expect(ttl(described_class.keys_for(conversation, kinds: %w[provisional]).first)).to be_within(5).of(Captain::ReplySuggestion::TTL_SECONDS)
    expect(described_class.read(other_conversation)).to be_nil
  end

  it 'withdraws only the provisional agent of the rejected request: the agent before it leads again' do
    described_class.confirm!(conversation, 84, request_id: 'r-1')
    described_class.remember_provisional!(conversation, 119, request_id: 'r-2')

    described_class.withdraw!(conversation, request_id: 'r-other')
    expect(described_class.read(conversation)).to eq(119)

    described_class.withdraw!(conversation, request_id: 'r-2')
    expect(described_class.read(conversation)).to eq(84)
  end

  it 'takes the newest agent of the person, whichever conversation of the thread set it (Контакт = Диалог)' do
    first, second = share_thread(conversation, other_conversation)
    described_class.confirm!(first, 120, request_id: 'r-1')
    expect(described_class.read(second)).to eq(120)

    described_class.confirm!(second, 84, request_id: 'r-2')

    expect(described_class.read(first)).to eq(84)
    expect(described_class.read(second)).to eq(84)
  end

  it 'is cleared with the conversation (resolved) and stores nothing without a conversation or an agent' do
    described_class.confirm!(conversation, 84, request_id: 'r-1')
    described_class.clear!(conversation)
    expect(described_class.read(conversation)).to be_nil

    expect(described_class.confirm!(nil, 84, request_id: 'r-1')).to be_nil
    expect(described_class.remember_provisional!(conversation, nil, request_id: 'r-1')).to be_nil
    expect(described_class.read(conversation)).to be_nil
  end

  it 'is cleared when the conversation is resolved' do
    described_class.confirm!(conversation, 84, request_id: 'r-1')

    CaptainListener.instance.conversation_resolved(Events::Base.new('conversation.resolved', Time.zone.now, conversation: conversation))

    expect(described_class.read(conversation)).to be_nil
  end

  describe '.agent_id_of' do
    it 'is the agent of a draft, of a "no reply needed" and of a staff request of the agent itself' do
      expect(described_class.agent_id_of(outcome: 'draft', agent: { 'id' => 84 })).to eq(84)
      expect(described_class.agent_id_of(outcome: 'no_reply', agent: { 'id' => 119 })).to eq(119)
      expect(described_class.agent_id_of(outcome: 'human_needed', reason_source: 'agent', agent: { 'id' => 120 })).to eq(120)
    end

    it 'is the agent a council left the dialog with, for an outcome and for a stored draft' do
      expect(described_class.agent_id_of(outcome: 'draft', agent: { 'id' => 84 }, lead_agent_id: 119)).to eq(119)
      expect(described_class.agent_id_of_result('agent' => { 'id' => 84 }, 'lead_agent_id' => 120)).to eq(120)
      expect(described_class.agent_id_of_result('agent' => { 'id' => 84 })).to eq(84)
    end

    it 'is nobody for a staff request of the router, a safety stop, a failure or a cancel' do
      expect(described_class.agent_id_of(outcome: 'human_needed', reason_source: 'router', agent: nil)).to be_nil
      expect(described_class.agent_id_of(outcome: 'human_needed', reason_source: 'safety', agent: { 'id' => 84 })).to be_nil
      expect(described_class.agent_id_of(outcome: 'failed', reason_code: 'router_unavailable')).to be_nil
      expect(described_class.agent_id_of(outcome: 'cancelled')).to be_nil
    end

    it 'is nobody for the anchor that answered only because no agent led the dialog' do
      expect(described_class.agent_id_of(outcome: 'draft', agent: { 'id' => 84 }, routing_default_to: 'anchor')).to be_nil
      stored = { 'agent' => { 'id' => 84 }, 'suggestion_meta' => { 'routing' => { 'default_to' => 'anchor' } } }
      expect(described_class.agent_id_of_result(stored)).to be_nil
      expect(described_class.agent_id_of(outcome: 'draft', agent: { 'id' => 119 }, routing_default_to: 'current')).to eq(119)
    end
  end

  describe '.withdraw_superseded!' do
    let(:manager) { create(:user, account: account) }
    let(:colleague) { create(:user, account: account) }

    def request_of(user)
      Captain::ReplySuggestion::RequestStore.create!('account_id' => account.id, 'user_id' => user.id, 'conversation_id' => conversation.id)
    end

    it "withdraws the provisional agent of the manager's earlier request, not the confirmed one or another manager's live one" do
      described_class.confirm!(conversation, 84, request_id: 'r-0')
      described_class.remember_provisional!(conversation, 119, request_id: request_of(manager)['id'])

      described_class.withdraw_superseded!(conversation, user_id: manager.id, keep_request_id: 'r-new')
      expect(described_class.read(conversation)).to eq(84)

      described_class.remember_provisional!(conversation, 120, request_id: request_of(colleague)['id'])
      described_class.withdraw_superseded!(conversation, user_id: manager.id, keep_request_id: 'r-new')
      expect(described_class.read(conversation)).to eq(120)
    end
  end

  describe 'ManualReply.mark!' do
    let(:manager) { create(:user, account: account) }
    let(:manual_reply) { described_class::ManualReply }

    def outgoing(target, at:, assisted: false, **attributes)
      content = assisted ? { copilot: { assisted: true } } : {}
      create(:message, conversation: target, account: account, message_type: :outgoing, sender: manager, content_attributes: content,
                       created_at: at, **attributes)
    end

    it 'ends the lead of every value written before a message the manager wrote by hand, in the person thread too' do
      share_thread(conversation, other_conversation)
      described_class.confirm!(other_conversation, 84, request_id: 'r-1')
      expect(described_class.read(conversation)).to eq(84)

      expect(manual_reply.mark!(outgoing(conversation, at: 1.second.from_now))).to be(true)

      expect(described_class.read(conversation)).to be_nil
      expect(described_class.read(other_conversation)).to be_nil
      travel 2.seconds do
        described_class.remember_provisional!(conversation, 119, request_id: 'r-2')
        expect(described_class.read(other_conversation)).to eq(119)
      end
    end

    it 'ignores the sent text of a used suggestion, notes, bots and customers, and an older message' do
      described_class.confirm!(conversation, 84, request_id: 'r-1')

      expect(manual_reply.mark!(outgoing(conversation, at: 1.second.from_now, assisted: true))).to be(false)
      expect(manual_reply.mark!(outgoing(conversation, at: 1.second.from_now, private: true))).to be(false)
      expect(manual_reply.mark!(create(:message, :bot_message, conversation: conversation, account: account))).to be(false)
      expect(manual_reply.mark!(create(:message, conversation: conversation, account: account, message_type: :incoming))).to be(false)
      expect(manual_reply.mark!(outgoing(conversation, at: 1.minute.ago))).to be(true)

      expect(described_class.read(conversation)).to eq(84)
    end
  end
end
