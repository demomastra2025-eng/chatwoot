require 'rails_helper'

RSpec.describe Captain::Llm::SystemPromptsService do
  describe '.faq_generator' do
    it 'renders the requested language from a file-backed prompt' do
      prompt = described_class.faq_generator('spanish')

      expect(prompt).to include('Generate the FAQs only in the spanish')
    end
  end

  describe '.copilot_response_generator' do
    it 'renders citation guidance only when feature_citation is enabled' do
      with_citations = described_class.copilot_response_generator('One Link', '- faq_lookup', { 'feature_citation' => true })
      without_citations = described_class.copilot_response_generator('One Link', '- faq_lookup', { 'feature_citation' => false })

      expect(with_citations).to include('Always include citations')
      expect(without_citations).not_to include('Always include citations')
    end
  end

  describe '.copilot_account_context' do
    it 'renders the account id and language from a file-backed prompt' do
      account = build_stubbed(:account, id: 42, locale: 'en')
      allow(account).to receive(:locale_english_name).and_return('English')

      prompt = described_class.copilot_account_context(account)

      expect(prompt).to include('42')
      expect(prompt).to include('English')
    end
  end

  describe '.copilot_conversation_context' do
    it 'renders the conversation and contact ids from a file-backed prompt' do
      conversation = build_stubbed(:conversation, display_id: 77, contact_id: 99)

      prompt = described_class.copilot_conversation_context(conversation)

      expect(prompt).to include('77')
      expect(prompt).to include('99')
    end
  end

  describe '.assistant_response_generator' do
    it 'renders contact context and additive config instructions from a file-backed prompt' do
      contact = {
        name: 'Diep Bui',
        email: 'diep@example.com',
        custom_attributes: { 'plan' => 'pro' }
      }

      prompt = described_class.assistant_response_generator(
        'Captain',
        'One Link',
        { 'instructions' => 'Use the FAQ tool first.' },
        contact: contact
      )

      expect(prompt).to include('[Contact Information]')
      expect(prompt).to include('- Name: Diep Bui')
      expect(prompt).to include('- plan: pro')
      expect(prompt).to include('Use the FAQ tool first.')
    end
  end

  describe '.website_analysis' do
    it 'returns the website analysis instructions from a file-backed prompt' do
      prompt = described_class.website_analysis

      expect(prompt).to include('Analyze the provided website content')
      expect(prompt).to include('Return only valid JSON')
    end
  end
end
