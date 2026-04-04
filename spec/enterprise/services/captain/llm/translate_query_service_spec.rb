require 'rails_helper'

RSpec.describe Captain::Llm::TranslateQueryService do
  let(:account) { create(:account, locale: 'en') }
  let(:service) { described_class.new(account: account) }

  before do
    allow(CLD3::NNetLanguageIdentifier).to receive(:new).and_raise(StandardError)
  end

  describe '#translate' do
    it 'builds a file-backed translation system prompt' do
      expect(service).to receive(:make_api_call) do |args|
        expect(args[:messages]).to match(
          [
            a_hash_including(
              role: 'system',
              content: a_string_including('Translate the query to spanish.')
            ),
            {
              role: 'user',
              content: 'Hello'
            }
          ]
        )

        { message: 'Hola' }
      end

      expect(service.translate('Hello', target_language: 'spanish')).to eq('Hola')
    end
  end
end
