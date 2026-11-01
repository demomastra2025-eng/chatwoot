# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Compliance::ExplicitAiConsentGate do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Гульнара') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :pending) }

  it 'is disabled (false) by default for all clinics and allows incoming messages immediately' do
    expect(Captain::AccountSettings.new(account).section('safety')['require_explicit_ai_consent']).to be(false)
    expect(described_class.enabled_for?(account)).to be(false)
    expect(described_class.blocked?(conversation)).to be(false)

    msg = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: 'Привет')
    expect(described_class.evaluate_incoming!(conversation: conversation, message: msg)).to eq(:allow)
  end

  context 'when clinic enables require_explicit_ai_consent in Captain::AccountSettings' do
    before do
      Captain::AccountSettings.new(account).update!('safety' => { 'require_explicit_ai_consent' => true })
    end

    # rubocop:disable RSpec/MultipleExpectations
    it 'blocks attachment AI & chat LLM calls until affirmative consent (including prefix answers like "Иә, жазылайын")' do
      expect(described_class.enabled_for?(account)).to be(true)
      expect(described_class.blocked?(conversation)).to be(true)

      msg1 = create(:message, account: account, inbox: inbox, conversation: conversation,
                              message_type: :incoming, content: 'Сәлеметсіз бе! УЗИ бағасы қанша?')
      audio_att = msg1.attachments.create!(account_id: account.id, file_type: :audio)
      image_att = msg1.attachments.create!(account_id: account.id, file_type: :image)

      expect(Messages::AudioTranscriptionService.new(audio_att).perform).to eq({ error: 'AI consent required' })
      expect(Messages::ImageDescriptionService.enabled_for?(image_att)).to be(false)

      expect(described_class.evaluate_incoming!(conversation: conversation, message: msg1)).to eq(:prompted)

      prompt_msg = conversation.messages.outgoing.last
      expect(prompt_msg.content).to include('Құпиялылық саясатына')
      expect(prompt_msg.content_attributes['compliance_gate']).to eq('ai_consent_prompt')

      msg2 = create(:message, account: account, inbox: inbox, conversation: conversation,
                              message_type: :incoming, content: 'Бүгін бос уақыт бар ма?')
      expect(described_class.evaluate_incoming!(conversation: conversation, message: msg2)).to eq(:awaiting_consent)
      prompt_count = conversation.messages.outgoing.reload.count { |m| m.content_attributes['compliance_gate'] == 'ai_consent_prompt' }
      expect(prompt_count).to eq(1)

      msg3 = create(:message, account: account, inbox: inbox, conversation: conversation,
                              message_type: :incoming, content: 'Иә, бүгін УЗИ керек еді')
      expect(described_class.evaluate_incoming!(conversation: conversation, message: msg3)).to eq(:allow)
      expect(described_class.blocked?(conversation.reload)).to be(false)
      expect(contact.reload.custom_attributes['ai_consent_status']).to eq('granted')
      expect(contact.custom_attributes['ai_consent_granted_at']).to be_present
      expect(contact.custom_attributes['ai_consent_message_id']).to eq(msg3.id)
    end
    # rubocop:enable RSpec/MultipleExpectations

    it 'hands off to human clinic staff with zero LLM calls when patient replies 0 or Оператор' do
      msg1 = create(:message, account: account, inbox: inbox, conversation: conversation,
                              message_type: :incoming, content: 'Здравствуйте, хочу записаться к терапевту')
      expect(described_class.evaluate_incoming!(conversation: conversation, message: msg1)).to eq(:prompted)
      expect(conversation.messages.outgoing.last.content).to include('Политике конфиденциальности')

      msg2 = create(:message, account: account, inbox: inbox, conversation: conversation,
                              message_type: :incoming, content: '0')
      expect(described_class.evaluate_incoming!(conversation: conversation, message: msg2)).to eq(:declined)
      expect(contact.reload.custom_attributes['ai_consent_status']).to eq('declined')
      expect(conversation.reload.status).to eq('open')
      expect(conversation.messages.outgoing.last.content).to include('администратора клиники')
    end
  end
end
