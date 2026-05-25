# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Captain LLM account routing' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      first_reply_created_at: Time.current
    )
  end
  let(:chat) { instance_double(RubyLLM::Chat) }

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-key')
    account.update!(captain_models: { 'assistant' => 'gpt-5.2' })

    allow(Llm::CapabilityPolicy).to receive(:ensure_chat_features_supported!)
    allow(Llm::StructuredOutputPolicy).to receive(:bind!).and_return(chat)
    allow(chat).to receive(:with_instructions).and_return(chat)
  end

  shared_examples 'an account-routed Captain LLM generation service' do |response_content, invocation|
    it 'builds chat with the conversation account and resolved assistant model' do
      response = instance_double(RubyLLM::Message, content: response_content)

      expect(Llm::ChatClient).to receive(:build).with(
        hash_including(
          account: account,
          model: 'gpt-5.2'
        )
      ).and_return(chat)
      allow(Llm::ChatClient).to receive(:ask).with(
        chat,
        kind_of(String),
        hash_including(account: account, model: 'gpt-5.2')
      ).and_return(response)

      instance_exec(&invocation)
    end
  end

  describe Captain::Llm::ContactNotesService do
    it_behaves_like(
      'an account-routed Captain LLM generation service',
      { notes: [] },
      -> { described_class.new(assistant, conversation).generate_and_update_notes }
    )
  end

  describe Captain::Llm::ContactAttributesService do
    it_behaves_like(
      'an account-routed Captain LLM generation service',
      { attributes: [] },
      -> { described_class.new(assistant, conversation).generate_and_update_attributes }
    )
  end

  describe Captain::Llm::ConversationFaqService do
    it_behaves_like(
      'an account-routed Captain LLM generation service',
      { faqs: [] },
      -> { described_class.new(assistant, conversation).generate_and_deduplicate }
    )
  end
end
# rubocop:enable RSpec/DescribeClass
