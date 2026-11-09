require 'rails_helper'

describe CaptainListener do
  let(:listener) { described_class.instance }
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:user) { create(:user, account: account) }
  let!(:assistant) { create(:captain_assistant, account: account, config: { feature_memory: true, feature_faq: true }) }

  describe '#conversation_resolved' do
    let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: user) }

    let(:event_name) { :conversation_resolved }
    let(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation) }

    before do
      create(:captain_inbox, inbox: inbox)
      # The agent the router gave the conversation to holds it, and owns what is learned from it.
      Captain::Conversation::AgentSession.new(conversation: conversation).update_routing(actor_id: assistant.id)
    end

    it 'learns nothing from a conversation that nobody holds: the knowledge belongs to an agent' do
      Captain::Conversation::AgentSession.new(conversation: conversation).update_routing(actor_id: nil)
      Captain::AccountSettings.new(account).update!('faq' => { 'generate_from_resolved' => true })
      expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

      listener.conversation_resolved(event)
    end

    it 'does not run notes or FAQ generation when the text channel is disabled' do
      inbox.captain_inbox.update!(ai_enabled: false)
      inbox.reload
      expect(Captain::Llm::ContactNotesService).not_to receive(:new)
      expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

      listener.conversation_resolved(event)
    end

    context 'when the old agent memory flag is enabled' do
      before do
        assistant.config['feature_memory'] = true
        assistant.config['feature_faq'] = false
        assistant.config['tool_access'] = { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } }
        assistant.save!
      end

      it 'does not generate contact notes while client memory is unavailable' do
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

        listener.conversation_resolved(event)
      end
    end

    context 'when feature_faq is enabled' do
      before do
        Captain::AccountSettings.new(account).update!('faq' => { 'generate_from_resolved' => true })
        assistant.config['feature_faq'] = true
        assistant.config['feature_memory'] = false
        assistant.config['tool_access'] = { 'agent' => { 'enabled' => true, 'tool_ids' => [] } }
        assistant.save!
      end

      it 'does not generate FAQs from resolved conversations' do
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)

        listener.conversation_resolved(event)
      end
    end

    context 'when a specialist is the current conversation agent' do
      let(:specialist) { create(:captain_assistant, account: account, config: { feature_memory: true, feature_faq: true }) }

      before do
        Captain::Conversation::AgentSession.new(conversation: conversation).update_routing(actor_id: specialist.id)
      end

      it 'does not generate FAQs from resolved conversations even when specialist is active' do
        Captain::AccountSettings.new(account).update!('faq' => { 'generate_from_resolved' => true })
        assistant.update!(config: { feature_memory: false, feature_faq: false })
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

        listener.conversation_resolved(event)
      end

      it 'does not generate FAQs when the account switch is off' do
        specialist.update!(config: { feature_memory: false, feature_faq: false })
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

        listener.conversation_resolved(event)
      end

      it 'does not fall back to another agent knowledge ownership when the specialist is inactive' do
        specialist.update!(active: false)
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

        listener.conversation_resolved(event)
      end

      it 'does not fall back to another agent knowledge ownership when the specialist is no longer an agent of the channel' do
        specialist.update_column(:usage_mode, 'internal_assistant') # rubocop:disable Rails/SkipsModelValidations
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

        listener.conversation_resolved(event)
      end
    end
  end
end
