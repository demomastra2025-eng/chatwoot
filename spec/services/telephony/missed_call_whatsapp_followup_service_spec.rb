# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::MissedCallWhatsappFollowupService do
  let(:account) { create(:account) }
  let(:voice_channel) do
    create(
      :channel_voice,
      account: account,
      provider: 'wazo',
      phone_number: '+77085012233',
      provider_config: {
        'provider_kind' => 'wazo',
        'number_ref' => 'wazo-num-1',
        'provider_connection_id' => 1
      }
    )
  end
  let(:voice_inbox) { voice_channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+77015556677', name: 'Алия') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: '+77015556677') }
  let(:voice_conversation) do
    create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
  end
  let(:missed_call_session) do
    Telephony::CallSession.create!(
      account: account,
      inbox: voice_inbox,
      contact: contact,
      conversation: voice_conversation,
      provider: 'wazo',
      external_call_ref: 'wazo-missed-wa-1',
      direction: 'inbound',
      status: 'no_answer',
      from_number: '+77015556677',
      to_number: '+77085012233',
      ended_at: Time.current
    )
  end

  before do
    Rails.cache.clear
  end

  describe '#perform' do
    context 'when configured with an official WABA channel (Channel::Whatsapp)' do
      let(:whatsapp_channel) do
        create(
          :channel_whatsapp,
          account: account,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
      end
      let(:whatsapp_inbox) { whatsapp_channel.inbox }

      before do
        voice_channel.update!(
          provider_config: (voice_channel.provider_config || {}).merge(
            'call_routing' => {
              'inbound' => {
                'whatsapp_followup' => {
                  'enabled' => true,
                  'inbox_id' => whatsapp_inbox.id,
                  'template_name' => 'missed_call_followup',
                  'template_language' => 'ru',
                  'cooldown_minutes' => 60
                }
              }
            }
          )
        )
      end

      it 'creates a template-backed outgoing WhatsApp message and enforces anti-spam cooldown on repeated missed calls' do
        result = described_class.new(call_session: missed_call_session).perform

        expect(result[:sent]).to be(true)
        message = Message.find(result[:message_id])
        expect(message.inbox_id).to eq(whatsapp_inbox.id)
        expect(message.message_type).to eq('outgoing')
        expect(message.additional_attributes['missed_call_whatsapp_followup']).to be(true)
        expect(message.additional_attributes['template_params']).to include(
          'name' => 'missed_call_followup',
          'language' => 'ru'
        )
        expect(missed_call_session.reload.metadata.dig('missed_call_whatsapp_followup', 'message_id')).to eq(message.id)

        # Second missed call from the same number within cooldown window is skipped
        second_missed_session = Telephony::CallSession.create!(
          account: account,
          inbox: voice_inbox,
          contact: contact,
          conversation: voice_conversation,
          provider: 'wazo',
          external_call_ref: 'wazo-missed-wa-2',
          direction: 'inbound',
          status: 'missed',
          from_number: '+77015556677',
          to_number: '+77085012233',
          ended_at: Time.current
        )

        second_result = described_class.new(call_session: second_missed_session).perform
        expect(second_result).to eq({ sent: false, reason: 'cooldown_active' })
      end

      it 'populates processed_params and renders body preview when the approved template has body placeholders' do
        whatsapp_inbox.channel.update_columns(
          message_templates: [
            {
              'name' => 'missed_call_followup',
              'status' => 'APPROVED',
              'language' => 'ru',
              'components' => [
                {
                  'type' => 'BODY',
                  'text' => 'Здравствуйте, {{1}}! Мы пропустили ваш звонок в {{2}}.'
                }
              ]
            }
          ]
        )

        result = described_class.new(call_session: missed_call_session).perform

        expect(result[:sent]).to be(true)
        message = Message.find(result[:message_id])
        expect(message.content).to eq("Здравствуйте, #{contact.name}! Мы пропустили ваш звонок в #{contact.phone_number}.")
        expect(message.additional_attributes.dig('template_params', 'processed_params', 'body')).to eq(
          '1' => contact.name,
          '2' => contact.phone_number
        )
      end
    end

    context 'when configured with a non-official WhatsApp channel' do
      let(:personal_whatsapp_inbox) do
        channel = create(:channel_api, account: account)
        inbox = channel.inbox
        inbox.update_columns(channel_type: 'Channel::WhatsappWeb')
        inbox
      end

      before do
        voice_channel.update!(
          provider_config: (voice_channel.provider_config || {}).merge(
            'call_routing' => {
              'inbound' => {
                'whatsapp_followup' => {
                  'enabled' => true,
                  'inbox_id' => personal_whatsapp_inbox.id,
                  'custom_message' => 'Здравствуйте! Мы пропустили ваш звонок. Напишите нам здесь.',
                  'cooldown_minutes' => 30
                }
              }
            }
          )
        )
      end

      it 'creates a custom text outgoing message without template_params' do
        result = described_class.new(call_session: missed_call_session).perform

        expect(result[:sent]).to be(true)
        message = Message.find(result[:message_id])
        expect(message.content).to eq('Здравствуйте! Мы пропустили ваш звонок. Напишите нам здесь.')
        expect(message.additional_attributes['template_params']).to be_nil
        expect(message.additional_attributes['missed_call_whatsapp_followup']).to be(true)
      end
    end
  end
end
