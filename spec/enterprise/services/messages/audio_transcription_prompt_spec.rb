require 'rails_helper'

RSpec.describe Messages::AudioTranscriptionPrompt do
  let(:context_sample) { described_class::CONTEXT_SAMPLE }

  it 'gives a transcription model a context sample written in Kazakh and Russian Cyrillic' do
    expect(context_sample).to include('Сәлеметсіз бе', 'Қабылдауға', 'Здравствуйте')
  end

  context 'when the workspace has no transcription prompt' do
    subject(:prompt) { described_class.new("  \n") }

    it 'sends the context sample to a transcription endpoint' do
      expect(prompt.for_transcription_endpoint).to eq(context_sample)
    end

    it 'tells a chat model to keep Kazakh in Kazakh spelling without translating' do
      expect(prompt.for_chat).to eq("#{described_class::CHAT_INSTRUCTION}\n#{described_class::CHAT_LANGUAGE_HINT}")
      expect(prompt.for_chat).to include('Kazakh Cyrillic', 'not in Kyrgyz spelling', 'do not translate')
    end

    it 'removes the context sample when the model returns it with the transcript' do
      expect(prompt.without_echoed_context("#{context_sample} Бағасы қанша?")).to eq('Бағасы қанша?')
      expect(prompt.without_echoed_context(context_sample)).to eq('')
    end

    it 'keeps a transcript that only shares words with the sample' do
      expect(prompt.without_echoed_context('Сәлеметсіз бе! Бағасы қанша?')).to eq('Сәлеметсіз бе! Бағасы қанша?')
    end
  end

  context 'when the workspace has its own transcription prompt' do
    subject(:prompt) { described_class.new('Клиника ЛОР, Алматы. Сәлеметсіз бе!') }

    it 'sends the workspace prompt instead of the context sample' do
      expect(prompt.for_transcription_endpoint).to eq('Клиника ЛОР, Алматы. Сәлеметсіз бе!')
    end

    it 'sends the workspace prompt to a chat model instead of the built-in hint' do
      expect(prompt.for_chat).to eq("#{described_class::CHAT_INSTRUCTION}\nКлиника ЛОР, Алматы. Сәлеметсіз бе!")
    end

    it 'leaves the transcript as it is' do
      expect(prompt.without_echoed_context("#{context_sample} Бағасы қанша?")).to eq("#{context_sample} Бағасы қанша?")
    end
  end
end
