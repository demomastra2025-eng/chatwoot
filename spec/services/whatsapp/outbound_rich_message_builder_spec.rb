require 'rails_helper'

RSpec.describe Whatsapp::OutboundRichMessageBuilder do
  describe '#build' do
    it 'builds an exact location payload and normalizes coordinates' do
      payload = {
        type: 'location',
        location: {
          latitude: '51.1694',
          longitude: '71.4491',
          name: 'OneLink HQ',
          address: 'Astana'
        }
      }

      expect(described_class.new(payload: payload).build).to eq(
        type: 'location',
        content: {
          latitude: 51.1694,
          longitude: 71.4491,
          name: 'OneLink HQ',
          address: 'Astana'
        }
      )
    end

    it 'whitelists and builds exact contacts payloads' do
      payload = {
        type: 'contacts',
        contacts: [{
          name: { formatted_name: 'Ada Lovelace', first_name: 'Ada', unsupported: 'drop' },
          phones: [{ phone: '+123****6789', type: 'mobile', wa_id: '123456789', unsupported: 'drop' }],
          emails: [{ email: 'ada@example.com', type: 'work' }],
          unsupported: 'drop'
        }]
      }

      expect(described_class.new(payload: payload).build).to eq(
        type: 'contacts',
        content: [{
          emails: [{ email: 'ada@example.com', type: 'work' }],
          name: { formatted_name: 'Ada Lovelace', first_name: 'Ada' },
          phones: [{ phone: '+123****6789', type: 'mobile', wa_id: '123456789' }]
        }]
      )
    end

    it 'builds an exact reaction payload when the target belongs to the conversation' do
      conversation = create(:conversation)
      target = create(:message, conversation: conversation, inbox: conversation.inbox, account: conversation.account, source_id: 'wamid.TARGET')
      payload = { type: 'reaction', reaction: { message_id: target.source_id, emoji: '👍' } }

      expect(described_class.new(payload: payload, conversation: conversation).build).to eq(
        type: 'reaction',
        content: { message_id: 'wamid.TARGET', emoji: '👍' }
      )
    end

    it 'rejects a reaction target outside the conversation' do
      conversation = create(:conversation)
      other_message = create(:message, source_id: 'wamid.OTHER')
      payload = { type: 'reaction', reaction: { message_id: other_message.source_id, emoji: '👍' } }

      expect do
        described_class.new(payload: payload, conversation: conversation).build
      end.to raise_error(ArgumentError, 'WhatsApp reaction target must belong to the same conversation')
    end

    it 'builds an exact CTA URL interactive payload' do
      payload = {
        type: 'cta_url',
        cta_url: {
          header: { type: 'image', link: 'https://example.com/banner.png' },
          body: 'Tap the button below to see available dates.',
          display_text: 'See dates',
          url: 'https://example.com/dates',
          footer: 'Dates subject to change.'
        }
      }

      expect(described_class.new(payload: payload).build).to eq(
        type: 'interactive',
        content: {
          type: 'cta_url',
          header: { type: 'image', image: { link: 'https://example.com/banner.png' } },
          body: { text: 'Tap the button below to see available dates.' },
          action: {
            name: 'cta_url',
            parameters: { display_text: 'See dates', url: 'https://example.com/dates' }
          },
          footer: { text: 'Dates subject to change.' }
        }
      )
    end

    it 'builds an exact WhatsApp Flow data_exchange interactive payload' do
      payload = {
        type: 'flow',
        flow: {
          flow_id: 'flow_booking_1',
          flow_token: 'olf1.claims.sig',
          body: 'Выберите удобное время записи.',
          flow_cta: 'Записаться',
          header: { type: 'text', text: 'Онлайн-запись' },
          footer: 'Занимает 30 секунд'
        }
      }

      expect(described_class.new(payload: payload).build).to eq(
        type: 'interactive',
        content: {
          type: 'flow',
          header: { type: 'text', text: 'Онлайн-запись' },
          body: { text: 'Выберите удобное время записи.' },
          action: {
            name: 'flow',
            parameters: {
              flow_message_version: '3',
              flow_token: 'olf1.claims.sig',
              flow_id: 'flow_booking_1',
              flow_cta: 'Записаться',
              flow_action: 'data_exchange'
            }
          },
          footer: { text: 'Занимает 30 секунд' }
        }
      )
    end

    it 'builds a WhatsApp Flow navigate interactive payload with screen and draft mode' do
      payload = {
        type: 'flow',
        flow: {
          flow_id: 'flow_survey_2',
          body: 'Оцените качество приёма.',
          flow_cta: 'Открыть',
          flow_action: 'navigate',
          mode: 'draft',
          flow_action_payload: {
            screen: 'WELCOME_SCREEN',
            data: { clinic_name: 'OneLink' }
          }
        }
      }

      expect(described_class.new(payload: payload).build).to eq(
        type: 'interactive',
        content: {
          type: 'flow',
          body: { text: 'Оцените качество приёма.' },
          action: {
            name: 'flow',
            parameters: {
              flow_message_version: '3',
              flow_token: 'unused',
              flow_id: 'flow_survey_2',
              flow_cta: 'Открыть',
              flow_action: 'navigate',
              mode: 'draft',
              flow_action_payload: {
                screen: 'WELCOME_SCREEN',
                data: { 'clinic_name' => 'OneLink' }
              }
            }
          }
        }
      )
    end

    it 'rejects malformed rich payloads' do
      malformed_payloads = [
        { type: 'location', location: { latitude: 91, longitude: 71 } },
        { type: 'contacts', contacts: [{ name: {} }] },
        { type: 'reaction', reaction: { message_id: 'wamid.1', emoji: '👍👍' } },
        { type: 'reaction', reaction: { message_id: 'wamid.1', emoji: 'a' } },
        { type: 'cta_url', cta_url: { body: 'Body', display_text: 'Open', url: 'javascript:alert(1)' } },
        { type: 'flow', flow: { flow_id: '', body: 'Body', flow_cta: 'Open' } },
        { type: 'flow', flow: { flow_id: 'bad id!', body: 'Body', flow_cta: 'Open' } },
        { type: 'flow', flow: { flow_id: 'flow_1', body: 'Body', flow_cta: 'Open 📅' } },
        { type: 'flow', flow: { flow_id: 'flow_1', body: 'Body', flow_cta: 'Open', flow_action: 'navigate' } }
      ]

      malformed_payloads.each do |payload|
        expect { described_class.new(payload: payload).build }.to raise_error(ArgumentError)
      end
    end
  end
end
