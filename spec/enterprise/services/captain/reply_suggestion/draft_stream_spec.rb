# frozen_string_literal: true

require 'rails_helper'

# The first words of a draft while the agent is still writing it.
RSpec.describe Captain::ReplySuggestion::DraftStream do
  subject(:stream) { described_class.new(broadcaster: broadcaster, identity: identity, clock: -> { clock[:now] }) }

  let(:identity) { { suggestion_request_id: 'sr-1', account_id: 7, conversation_id: 12, conversation_record_id: 99 } }
  let(:broadcaster) { instance_double(Captain::ReplySuggestion::Broadcaster) }
  let(:clock) { { now: 100.0 } }
  let(:sent) { [] }

  before do
    allow(broadcaster).to receive(:preview) { |data| sent << data }
  end

  it 'requests the outcome before the response in the provider schema' do
    fields = Llm::StructuredOutputSchema.definition_for(Captain::SuggestionResponseSchema).fetch('properties').keys

    expect(fields.index('response_mode')).to be < fields.index('response')
  end

  def advance(seconds)
    clock[:now] += seconds
  end

  def texts
    sent.pluck(:text)
  end

  describe 'what is shown' do
    it 'sends the text of the answer as it grows, to the request it belongs to, with a number for the order' do
      stream.feed('{"patient_language":"ru","response_mode":"reply","response":"Здравствуйте, ')
      advance(0.25)
      stream.feed('Анна! Приём стоит 8000 тенге.')

      expect(sent).to eq(
        [identity.merge(seq: 1, text: 'Здравствуйте,'), identity.merge(seq: 2, text: 'Здравствуйте, Анна! Приём стоит 8000 тенге.')]
      )
    end

    it 'sends at most one preview every 0.2 s and the latest text when the interval has passed' do
      stream.feed('{"response_mode":"reply","response":"Здравствуйте, Анна')
      advance(0.05)
      stream.feed('! Приём')
      advance(0.05)
      stream.feed(' стоит')

      expect(texts).to eq(['Здравствуйте, Анна'])

      advance(0.11)
      stream.feed(' 8000')

      expect(texts).to eq(['Здравствуйте, Анна', 'Здравствуйте, Анна! Приём стоит 8000'])
    end

    it 'does not bypass the broadcast interval when the model call ends' do
      stream.feed('{"response_mode":"reply","response":"Здравствуйте, Анна')
      advance(0.05)
      stream.feed('! Приём стоит 8000 тенге."')

      expect(texts).to eq(['Здравствуйте, Анна'])

      stream.finish!

      expect(texts).to eq(['Здравствуйте, Анна'])

      advance(0.2)
      stream.finish!

      expect(texts).to eq(['Здравствуйте, Анна', 'Здравствуйте, Анна! Приём стоит 8000 тенге.'])
    end

    it 'does not repeat a text it has already sent' do
      stream.feed('{"response_mode":"reply","response":"Здравствуйте, Анна!"')
      stream.finish!
      advance(1)
      stream.feed(',"reasoning":"по прайсу"')
      stream.finish!

      expect(texts).to eq(['Здравствуйте, Анна!'])
    end

    it 'waits for a few words before the first preview, but not when the field is already complete' do
      stream.feed('{"response_mode":"reply","response":"Зд')
      expect(sent).to be_empty

      stream.feed('равствуйте, Анна')
      expect(texts).to eq(['Здравствуйте, Анна'])

      short = described_class.new(broadcaster: broadcaster, identity: identity, clock: -> { clock[:now] })
      short.feed('{"response_mode":"reply","response":"Хорошо!"')
      expect(texts.last).to eq('Хорошо!')
    end

    it 'shows nothing for an answer that leaves the text empty (suppress, human)' do
      stream.feed('{"patient_language":"ru","response":"","response_mode":"human","operator_note":"нужен администратор"}')
      stream.finish!

      expect(sent).to be_empty
    end

    it 'shows nothing when the mode is human or suppress, even if the model writes text' do
      %w[human suppress].each do |mode|
        candidate = described_class.new(broadcaster: broadcaster, identity: identity, clock: -> { clock[:now] })
        candidate.feed(%({"response_mode":"#{mode}","response":"Это решит администратор, ждите ответа"}))
        candidate.finish!
      end

      expect(sent).to be_empty
    end

    it 'buffers text until a late reply mode is known' do
      stream.feed('{"response":"Это решит администратор, ждите ответа')
      expect(texts).to be_empty

      stream.feed('","response_mode":"reply"')

      expect(texts).to eq(['Это решит администратор, ждите ответа'])
    end

    it 'never reveals text when a late mode says human' do
      stream.feed('{"response":"Это решит администратор, ждите ответа')
      stream.feed('","response_mode":"human"}')
      stream.finish!

      expect(texts).to be_empty
    end

    it 'takes the text back at the end of the call when the answer turns out to be broken' do
      stream.feed('{"response_mode":"reply","response":"Это решит администратор, ждите ответа')
      stream.feed('" nonsense')
      stream.finish!

      expect(texts).to eq(['Это решит администратор, ждите ответа', ''])
    end

    it 'shows the text as the run cleans it: without a send stamp the model copied into the reply' do
      stream.feed('{"response_mode":"reply","response":"[Sat 24.10 09:5')
      expect(sent).to be_empty

      stream.feed('0] Здравствуйте, Анна, приём в 10:00')

      expect(texts).to eq(['Здравствуйте, Анна, приём в 10:00'])
      expect(texts.last).to eq(Captain::PromptClock.unstamped('[Sat 24.10 09:50] Здравствуйте, Анна, приём в 10:00').strip)
    end

    it 'holds a text that starts with a bracket until it is clear that it is no stamp' do
      stream.feed('{"response_mode":"reply","response":"[Анна], здрав')
      expect(sent).to be_empty

      advance(0.25)
      stream.feed('ствуйте! Приём стоит 8000 тенге')

      expect(texts).to eq(['[Анна], здравствуйте! Приём стоит 8000 тенге'])
    end

    it 'never flashes a streamed provider safety refusal and cleanly previews the fallback answer that follows' do
      stream.feed(%({"patient_language":"en","response_mode":"reply","response":"I'm sorry, but ))
      advance(0.25)
      stream.feed('I cannot assist with that request.","operator_note":"","reasoning":"refusal","artifact_ids":[]}')
      stream.finish!

      expect(sent).to be_empty

      advance(0.25)
      stream.feed('{"patient_language":"ru","response_mode":"reply","response":"Здравствуйте! Приём уролога стоит 8000 тенге."}')
      stream.finish!

      expect(texts).to eq(['Здравствуйте! Приём уролога стоит 8000 тенге.'])
    end

    it 'holds longer polite refusal prefixes (Sorry, but / As an AI language model / I am unable) without flashing' do
      stream.feed(%({"response_mode":"reply","response":"As an AI language model, I apologize, but I am not able to assist you ))
      advance(0.25)
      stream.feed('with that request. If you have any other questions, feel free to ask."}')
      stream.finish!

      expect(sent).to be_empty
    end

    it 'still broadcasts a legitimate clinic English apology once the sentence is complete' do
      stream.feed(%({"response_mode":"reply","response":"I'm sorry, Dr. Ivanov ))
      expect(sent).to be_empty

      advance(0.25)
      stream.feed('is fully booked on Sunday."}')

      expect(texts).to eq(["I'm sorry, Dr. Ivanov is fully booked on Sunday."])
    end
  end

  describe '#reset!' do
    it 'takes back what was shown when a tool is about to run, and reads the next answer from the start' do
      stream.feed('{"response_mode":"reply","response":"Сейчас проверю расписание"')
      stream.reset!
      stream.feed('{"response_mode":"reply","response":"Приём в 10:00 свободен"')

      expect(texts).to eq(['Сейчас проверю расписание', '', 'Приём в 10:00 свободен'])
      expect(sent.pluck(:seq)).to eq([1, 2, 3])
    end

    it 'sends nothing when nothing was shown' do
      stream.reset!

      expect(sent).to be_empty
    end

    it 'follows the new document when the model is asked again after an answer that was not valid' do
      stream.feed('{"response_mode":"reply","response":"Первый вариант ответа","reasoning":""}')
      stream.feed('{"response_mode":"reply","response":"Второй вариант ответа","reasoning":"по прайсу"}')

      expect(texts).to eq(['Первый вариант ответа', '', 'Второй вариант ответа'])
    end

    it 'does not take a bracket inside the text for a new document' do
      stream.feed('{"response_mode":"reply","response":"Адрес клиники: ул. Абая 1, ')
      stream.feed('{') # a piece that starts like a document, in the middle of the text
      advance(0.25)
      stream.feed('вход со двора}"')

      expect(texts.last).to eq('Адрес клиники: ул. Абая 1, {вход со двора}')
    end
  end

  describe 'when something goes wrong' do
    it 'never raises into the model call, and stops previewing after the first failure' do
      allow(broadcaster).to receive(:preview).and_raise(RuntimeError, 'redis down')
      allow(Rails.logger).to receive(:warn)

      expect { stream.feed('{"response_mode":"reply","response":"Здравствуйте, Анна, добрый день"') }.not_to raise_error
      expect { stream.feed(',"reasoning":"по прайсу"') }.not_to raise_error
      expect { stream.finish! }.not_to raise_error

      expect(broadcaster).to have_received(:preview).once
      expect(Rails.logger).to have_received(:warn).with(/draft preview stopped: RuntimeError/).once
    end

    it 'keeps quiet for a document that is not JSON' do
      stream.feed('Конечно, вот ответ: {"response": "x"}')
      stream.finish!

      expect(sent).to be_empty
    end
  end
end
