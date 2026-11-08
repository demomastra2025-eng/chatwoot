require 'rails_helper'

RSpec.describe Captain::Labels::SmartTaggingService do
  let(:account) { create(:account, captain_features: { 'label_suggestion' => true }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let!(:label_urgent) { create(:label, account: account, title: 'острая-боль', description: 'Пациент с острой болью') }
  let!(:label_dms) { create(:label, account: account, title: 'дмс', description: 'Лечение по страховке ДМС') }
  let!(:label_implant) { create(:label, account: account, title: 'имплантация', description: 'Интересуется имплантацией') }

  describe '.meaningful_message?' do
    it 'returns false for trivial greetings and acknowledgements' do
      %w[Ок спасибо Здравствуйте Да хорошо 👍].each do |text|
        msg = build(:message, conversation: conversation, message_type: :incoming, content: text)
        expect(described_class.meaningful_message?(msg)).to be(false), "Expected '#{text}' to be trivial"
      end
    end

    it 'returns true for substantive customer messages' do
      msg = build(:message, conversation: conversation, message_type: :incoming,
                            content: 'У ребенка сильная зубная боль, можно сегодня попасть к врачу?')
      expect(described_class.meaningful_message?(msg)).to be(true)
    end
  end

  describe '#perform' do
    before do
      create(:message, conversation: conversation, message_type: :incoming,
                       content: 'Здравствуйте! У меня острая боль в зубе, возможно ли лечение по страховке?')
    end

    it 'auto-applies labels with confidence >= 0.85, soft-suggests 0.60..0.84, and ignores < 0.60' do
      multi_result = Llm::OpenRouterDecisionClient::MultiResult.new(
        model: 'perplexity/pplx-decider-flash-v1.2',
        provider: 'Perplexity',
        answers: {
          'label_0' => { 'choice' => 'apply', 'confidence' => 0.92,
                         'probabilities' => { 'apply' => 0.92, 'skip' => 0.08 } }.with_indifferent_access,
          'label_1' => { 'choice' => 'apply', 'confidence' => 0.71,
                         'probabilities' => { 'apply' => 0.71, 'skip' => 0.29 } }.with_indifferent_access,
          'label_2' => { 'choice' => 'apply', 'confidence' => 0.45,
                         'probabilities' => { 'apply' => 0.45, 'skip' => 0.55 } }.with_indifferent_access
        },
        usage: { 'input_tokens' => 95, 'output_tokens' => 3 }
      )

      expect(Llm::Runtime).to receive(:decide_many).with(
        hash_including(
          feature: :label_suggestion,
          account: account,
          conversation: conversation
        )
      ).and_return(multi_result)

      result = described_class.new(conversation: conversation).perform

      expect(result[:auto_applied]).to eq(['острая-боль'])
      expect(result[:suggested]).to eq(['дмс'])
      expect(conversation.reload.label_list).to include('острая-боль')
      expect(conversation.label_list).not_to include('дмс', 'имплантация')
      expect(conversation.additional_attributes['ai_suggested_labels']).to eq(['дмс'])
    end

    it 'never re-applies or suggests a label that a human operator manually removed' do
      conversation.update_columns(
        additional_attributes: conversation.additional_attributes.to_h.merge(
          'human_removed_labels' => ['острая-боль']
        )
      )

      multi_result = Llm::OpenRouterDecisionClient::MultiResult.new(
        model: 'perplexity/pplx-decider-flash-v1.2',
        provider: 'Perplexity',
        answers: {
          'label_0' => { 'choice' => 'apply', 'confidence' => 0.97,
                         'probabilities' => { 'apply' => 0.97, 'skip' => 0.03 } }.with_indifferent_access,
          'label_1' => { 'choice' => 'apply', 'confidence' => 0.88,
                         'probabilities' => { 'apply' => 0.88, 'skip' => 0.12 } }.with_indifferent_access,
          'label_2' => { 'choice' => 'skip', 'confidence' => 0.95,
                         'probabilities' => { 'apply' => 0.05, 'skip' => 0.95 } }.with_indifferent_access
        },
        usage: { 'input_tokens' => 95, 'output_tokens' => 3 }
      )

      allow(Llm::Runtime).to receive(:decide_many).and_return(multi_result)

      result = described_class.new(conversation: conversation).perform

      expect(result[:auto_applied]).to eq(['дмс'])
      expect(conversation.reload.label_list).to eq(['дмс'])
      expect(conversation.label_list).not_to include('острая-боль')
    end
  end

  describe 'Captain::Labels::AutoTagConversationJob coalescing' do
    it 'skips execution if a newer incoming message arrived after trigger_message_id' do
      msg1 = create(:message, conversation: conversation, message_type: :incoming,
                              content: 'У меня болит зуб с утра')
      create(:message, conversation: conversation, message_type: :incoming,
                       content: 'И еще щека опухла сильно')

      expect(described_class).not_to receive(:new)

      Captain::Labels::AutoTagConversationJob.perform_now(conversation.id, trigger_message_id: msg1.id)
    end

    it 'executes SmartTaggingService for the latest incoming message' do
      create(:message, conversation: conversation, message_type: :incoming,
                       content: 'У меня болит зуб с утра')
      msg2 = create(:message, conversation: conversation, message_type: :incoming,
                              content: 'И еще щека опухла сильно')

      service_double = instance_double(described_class, perform: { auto_applied: ['острая-боль'], suggested: [] })
      expect(described_class).to receive(:new).with(conversation: conversation).and_return(service_double)

      Captain::Labels::AutoTagConversationJob.perform_now(conversation.id, trigger_message_id: msg2.id)
    end
  end
end
