# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PatientLanguageDetector do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:detector) { described_class.new(conversation: conversation, assistant: assistant) }
  let(:model) { 'openai/gpt-6-luna-decisions' }
  let(:decision) { Struct.new(:choice) }

  before do
    allow(Llm::Config).to receive(:model_for).with(feature: :language_detection, account: account, fallback: nil).and_return(model)
  end

  def patient_says(text)
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: text)
  end

  def choose(value)
    allow(Llm::Runtime).to receive(:decide).and_return(decision.new(value))
  end

  it 'sends one decision with the latest incoming patient message' do
    21.times { |i| patient_says("Fake patient words #{i}") }
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :outgoing,
                     content: 'Fake staff words')
    choose('kk')

    expect(detector.call).to eq('kk')
    expect(Llm::Runtime).to have_received(:decide).once.with(hash_including(
                                                               feature: :language_detection, model: model,
                                                               input: { messages: 'Fake patient words 20' },
                                                               options: { decision_criteria: described_class::CRITERIA,
                                                                          decision_instructions: described_class::INSTRUCTIONS }
                                                             ))
    expect(conversation.reload.additional_attributes[described_class::ATTRIBUTE]).to eq('kk')
  end

  it 'uses a voice transcription and skips an attachment without text' do
    skipped = patient_says('')
    skipped.attachments.create!(account: account, file_type: :image)
    voice = patient_says('')
    voice.attachments.create!(account: account, file_type: :audio, meta: { transcribed_text: 'Fake voice words' })
    choose('en')

    expect(detector.call).to eq('en')
    expect(Llm::Runtime).to have_received(:decide).with(hash_including(input: { messages: 'Fake voice words' }))
  end

  it 'keeps the last decided language for unknown and clears it for other' do
    patient_says('Fake short reply')
    choose('ru')
    expect(detector.call).to eq('ru')
    choose('unknown')
    expect(detector.call).to eq('ru')
    choose('other')
    expect(detector.call).to be_nil
    choose('unknown')
    expect(detector.call).to be_nil
  end

  it 'returns no hint on timeout and logs only the error class' do
    patient_says('Fake private patient text')
    stub_const("#{described_class}::TIMEOUT_SECONDS", 0.01)
    allow(Llm::Runtime).to receive(:decide) { sleep(1) }
    allow(Rails.logger).to receive(:warn)

    expect(detector.call).to be_nil
    expect(Rails.logger).to have_received(:warn).with('[CAPTAIN][PatientLanguage] unavailable error_class=Timeout::Error')
  end
end
