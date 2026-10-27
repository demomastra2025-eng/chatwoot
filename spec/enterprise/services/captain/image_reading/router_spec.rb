require 'rails_helper'

RSpec.describe Captain::ImageReading::Router do
  let(:account) { create(:account) }
  let(:bytes) { Vips::Image.black(600, 400, bands: 3).new_from_image([90, 90, 90]).write_to_buffer('.jpg') }
  let(:picture) { Captain::ImageReading::Picture.new(bytes: bytes, content_type: 'image/jpeg') }
  let(:router) { described_class.new(account: account, picture: picture, observability: { attachment_id: 7 }) }

  def answer(handwriting:, choice: nil, confidence: nil, usage: { 'cost' => 0.00002 })
    probabilities = handwriting.nil? ? {} : { 'handwriting' => handwriting, 'no_handwriting' => 1.0 - handwriting }
    Llm::OpenRouterDecisionClient::Result.new(
      choice: choice || (handwriting.to_f >= 0.5 ? 'handwriting' : 'no_handwriting'), confidence: confidence,
      probabilities: probabilities, answers: {}, model: 'perplexity/pplx-decider-v1.2-20261020', provider: 'Perplexity',
      request_id: 'gen-1', usage: usage
    )
  end

  describe 'the question to the decision model' do
    before { allow(Llm::Runtime).to receive(:decide).and_return(answer(handwriting: 0.1)) }

    it 'asks the image-routing feature with the image as a 1024 px jpeg data url in the state, and no fallback model', :aggregate_failures do
      router.decide

      expect(Llm::Runtime).to have_received(:decide) do |**request|
        expect(request[:feature]).to eq(:image_routing)
        expect(request[:account]).to eq(account)
        expect(request).not_to have_key(:model) # the model is the platform setting, resolved by the runtime
        text, image = request[:input]
        expect(text).to be_a(String)
        expect(image[:type]).to eq('image_url')
        expect(image.dig(:image_url, :url)).to start_with('data:image/jpeg;base64,')
        expect(request[:options][:decision_criteria].keys).to eq(%w[handwriting no_handwriting])
        expect(request[:options][:decision_fallback]).to be(false)
        expect(request[:observability]).to eq(attachment_id: 7)
      end
    end

    # The wording and the threshold were measured together on PROD (see the comment of the class). A change of either one needs a new
    # measurement, and this example then changes with it.
    it 'asks the question that was measured with the threshold of 0.3' do
      expect(described_class::THRESHOLD).to eq(0.3)
      expect(described_class::QUESTION).to eq('Is anything on this image written by hand? Pick exactly one.')
      expect(described_class::QUESTION_CRITERIA['handwriting']).to start_with('Handwritten text anywhere on the image')
      expect(described_class::QUESTION_CRITERIA['handwriting']).to include('printed form or other document filled in or marked by hand')
      expect(described_class::QUESTION_CRITERIA['no_handwriting']).to start_with('Printed or typed text only, or no text')
    end

    it 'names no kind of business in the question' do
      words = [described_class::QUESTION, described_class::STATE_TEXT, *described_class::QUESTION_CRITERIA.values].join(' ')

      expect(words).not_to match(/clinic|patient|medic|doctor|hospital|клиник|пациент|медицин|врач/i)
    end
  end

  describe 'the choice of the reader' do
    {
      0.0 => :ordinary, 0.1 => :ordinary, 0.29 => :ordinary, 0.3 => :handwriting, 0.31 => :handwriting, 0.9 => :handwriting, 1.0 => :handwriting
    }.each do |probability, reader|
      it "reads with the #{reader} reader when P(handwriting) is #{probability}" do
        allow(Llm::Runtime).to receive(:decide).and_return(answer(handwriting: probability))

        decision = router.decide

        expect(decision.reader).to eq(reader)
        expect(decision.status).to eq('ok')
        expect(decision.probability).to eq(probability)
        expect(decision.model).to eq('perplexity/pplx-decider-v1.2-20261020')
      end
    end

    it 'takes the probability of the choice from the confidence when the answer has no probabilities' do
      allow(Llm::Runtime).to receive(:decide).and_return(answer(handwriting: nil, choice: 'no_handwriting', confidence: 0.8))
      expect(router.decide.probability).to be_within(1e-9).of(0.2)

      allow(Llm::Runtime).to receive(:decide).and_return(answer(handwriting: nil, choice: 'handwriting', confidence: 0.6))
      expect(router.decide.probability).to eq(0.6)
    end

    it 'follows the choice when the answer carries no number at all' do
      allow(Llm::Runtime).to receive(:decide).and_return(answer(handwriting: nil, choice: 'handwriting'))
      expect(router.decide.reader).to eq(:handwriting)

      allow(Llm::Runtime).to receive(:decide).and_return(answer(handwriting: nil, choice: 'no_handwriting'))
      expect(router.decide.reader).to eq(:ordinary)
    end

    it 'keeps the latency and what the call cost' do
      allow(Llm::Runtime).to receive(:decide).and_return(answer(handwriting: 0.1, usage: { 'cost' => 0.00002 }))

      decision = router.decide

      expect(decision.cost).to eq(0.00002)
      expect(decision.latency_ms).to be >= 0
    end
  end

  describe 'when the router does not answer' do
    [
      Llm::OpenRouterDecisionClient::Error.new('OpenRouter decision transport unavailable.'),
      Timeout::Error.new,
      ArgumentError.new('Decision request too large.'),
      RubyLLM::ConfigurationError.new('no key'),
      StandardError.new('budget exhausted')
    ].each do |failure|
      it "reads with the handwriting reader (the safe one) on #{failure.class.name}" do
        allow(Llm::Runtime).to receive(:decide).and_raise(failure)

        decision = router.decide

        expect(decision.reader).to eq(:handwriting)
        expect(decision.status).to eq('failed')
        expect(decision).to be_failed
        expect(decision.probability).to be_nil
        expect(decision.error_class).to be_present
      end
    end

    it 'logs the class of the error and nothing of the image' do
      allow(Llm::Runtime).to receive(:decide).and_raise(Llm::OpenRouterDecisionClient::Error, 'HTTP 429 data:image/jpeg;base64,AAAA')
      allow(Rails.logger).to receive(:warn)

      router.decide

      expect(Rails.logger).to have_received(:warn).with(/ImageRouter.*Llm::OpenRouterDecisionClient::Error/) do |line|
        expect(line).not_to include('base64')
      end
    end
  end
end
