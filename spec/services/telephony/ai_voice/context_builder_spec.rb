require 'rails_helper'

RSpec.describe Telephony::AiVoice::ContextBuilder do
  describe 'voice response policy' do
    subject(:builder) { described_class.allocate }

    before do
      builder.instance_variable_set(
        :@ai_settings,
        'max_sentences' => 4,
        'language' => 'ru-KZ',
        'input_language_priorities' => %w[ru-KZ kk-KZ en-US]
      )
    end

    it 'allows a longer complete answer when the caller explicitly asks for detail' do
      expect(builder.send(:response_length_prompt)).to include('не длиннее 4 предложений', 'не обрывай')
    end

    it 'makes ordered input languages explicit for short ambiguous speech' do
      expect(builder.send(:language_priority_prompt)).to include('ru-KZ → kk-KZ → en-US', 'короткой')
    end

    it 'requires a concrete next step instead of generic repeated prompts' do
      expect(described_class::DEFAULT_SYSTEM_PROMPT).to include('следующий полезный шаг', 'Не повторяй общие фразы')
    end
  end

  describe '#captain_runtime_state_for_prompt' do
    let(:account) { create(:account, captain_runtime: { 'assistant_thinking_effort' => 'low' }) }
    let(:whatsapp_channel) do
      create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
    end
    let(:inbox) { whatsapp_channel.inbox }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        inbox: inbox,
        number_binding: nil,
        external_call_ref: 'whatsapp:wacid-test-call'
      )
    end

    before do
      create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    end

    it 'uses the lightweight runtime preferences instead of full captain preferences' do
      builder = described_class.new(
        params: {
          'call_ref' => call_session.external_call_ref,
          'account_id' => account.id
        }
      )
      resolved_account = builder.send(:account)

      expect(resolved_account).not_to receive(:captain_preferences)
      expect(resolved_account).to receive(:captain_runtime_preferences).and_call_original

      state = builder.send(:captain_runtime_state_for_prompt)

      expect(state[:captain_runtime]['assistant_thinking_effort']).to eq('low')
    end

    it 'keeps another clinical patient out of the voice prompt state' do
      account.enable_features!('scheduling')
      assistant.update!(usage_mode: 'external_agent')
      own = create(:scheduling_appointment, account: account, contact: conversation.contact,
                                            starts_at: 2.hours.from_now, ends_at: 150.minutes.from_now)
      child = create(:contact, account: account)
      create(:scheduling_appointment, account: account, contact: conversation.contact, patient_contact: child,
                                      conversation: conversation, starts_at: 10.minutes.from_now, ends_at: 40.minutes.from_now,
                                      client_comment: 'Private child clinical comment')
      builder = described_class.new(params: { 'call_ref' => call_session.external_call_ref, 'account_id' => account.id })

      state = builder.send(:captain_runtime_state_for_prompt)

      expect(state.dig(:appointment, :id)).to eq(own.id)
      expect(state.fetch(:appointment).keys).to contain_exactly(:id, :resource_name, :start_date, :start_time, :status, :summary)
      summary = state.dig(:appointment, :summary)
      expect(summary).to include(shown: 1, total: 1, scope: { kind: 'current_contact', contact_id: conversation.contact_id })
      expect(summary[:groups].flat_map { |group| group[:items].pluck(:id) }).to eq([own.id])
      expect(state.to_json).not_to include('Private child clinical comment')
    end
  end
end
