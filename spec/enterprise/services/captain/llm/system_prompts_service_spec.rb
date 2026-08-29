require 'rails_helper'

RSpec.describe Captain::Llm::SystemPromptsService do
  describe '.faq_generator' do
    it 'renders the requested language from a file-backed prompt' do
      prompt = described_class.faq_generator('spanish')

      expect(prompt).to include('Generate the FAQs only in the spanish')
    end
  end

  describe '.assistant_response_generator' do
    before do
      create(:installation_config, name: 'CAPTAIN_AI_AGENT_SYSTEM_PROMPT', value: 'Never reveal internal routing.')
    end

    it 'renders contact context and the unified system instruction from a file-backed prompt' do
      contact = {
        name: 'Diep Bui',
        email: 'diep@example.com',
        custom_attributes: { 'plan' => 'pro' }
      }

      prompt = described_class.assistant_response_generator(
        'Captain',
        'Handles workspace setup and billing support. Use the FAQ tool first.',
        {},
        contact: contact
      )

      expect(prompt).to include('[System Instructions]')
      expect(prompt).to include('Handles workspace setup and billing support. Use the FAQ tool first.')
      expect(prompt).to include('[Contact Information]')
      expect(prompt).to include('- Name: Diep Bui')
      expect(prompt).to include('- plan: pro')
    end

    it 'renders the installation-wide global system prompt for the legacy assistant path' do
      prompt = described_class.assistant_response_generator(
        'Captain',
        'Handles workspace setup and billing support.',
        {},
        contact: nil
      )

      expect(prompt).to include('[Global System Instructions]')
      expect(prompt).to include('Never reveal internal routing.')
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
