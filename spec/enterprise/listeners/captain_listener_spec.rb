require 'rails_helper'

describe CaptainListener do
  let(:listener) { described_class.instance }
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account, config: { feature_memory: true, feature_faq: true }) }

  describe '#conversation_resolved' do
    let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: user) }

    let(:event_name) { :conversation_resolved }
    let(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    end

    it 'does not run notes or FAQ generation when the text channel is disabled' do
      inbox.captain_inbox.update!(ai_enabled: false)
      inbox.reload
      expect(Captain::Llm::ContactNotesService).not_to receive(:new)
      expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

      listener.conversation_resolved(event)
    end

    context 'when feature_memory is enabled' do
      before do
        assistant.config['feature_memory'] = true
        assistant.config['feature_faq'] = false
        assistant.config['tool_access'] = { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } }
        assistant.save!
      end

      it 'generates and updates notes' do
        expect(Captain::Llm::ContactNotesService)
          .to receive(:new)
          .with(assistant, conversation)
          .and_return(instance_double(Captain::Llm::ContactNotesService, generate_and_update_notes: nil))
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

        listener.conversation_resolved(event)
      end
    end

    context 'when feature_faq is enabled' do
      before do
        assistant.config['feature_faq'] = true
        assistant.config['feature_memory'] = false
        assistant.config['tool_access'] = { 'agent' => { 'enabled' => true, 'tool_ids' => [] } }
        assistant.save!
      end

      it 'generates and deduplicates FAQs' do
        expect(Captain::Llm::ConversationFaqService)
          .to receive(:new)
          .with(assistant, conversation)
          .and_return(instance_double(Captain::Llm::ConversationFaqService, generate_and_deduplicate: false))
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)

        listener.conversation_resolved(event)
      end
    end

    context 'when a specialist is the current conversation agent' do
      let(:specialist) { create(:captain_assistant, account: account, config: { feature_memory: true, feature_faq: true }) }

      before do
        assistant.update!(handoff_agent_ids: [specialist.id])
        Captain::Conversation::AgentSession.new(entry: assistant, conversation: conversation).update_routing(actor_id: specialist.id)
      end

      it 'uses the specialist capabilities and knowledge ownership when the entry disables both features' do
        assistant.update!(config: { feature_memory: false, feature_faq: false })
        expect(Captain::Llm::ContactNotesService)
          .to receive(:new).with(specialist, conversation)
          .and_return(instance_double(Captain::Llm::ContactNotesService, generate_and_update_notes: nil))
        expect(Captain::Llm::ConversationFaqService)
          .to receive(:new).with(specialist, conversation)
          .and_return(instance_double(Captain::Llm::ConversationFaqService, generate_and_deduplicate: false))

        listener.conversation_resolved(event)
      end

      it 'does not inherit the entry capabilities when the specialist disables both features' do
        specialist.update!(config: { feature_memory: false, feature_faq: false })
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

        listener.conversation_resolved(event)
      end

      it 'does not fall back to entry knowledge ownership when the specialist is inactive' do
        specialist.update!(active: false)
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

        listener.conversation_resolved(event)
      end

      it 'does not fall back to entry knowledge ownership when the specialist is no longer reachable' do
        assistant.update!(handoff_agent_ids: [])
        expect(Captain::Llm::ContactNotesService).not_to receive(:new)
        expect(Captain::Llm::ConversationFaqService).not_to receive(:new)

        listener.conversation_resolved(event)
      end
    end
  end
end
