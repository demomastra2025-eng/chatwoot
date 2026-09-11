## the older specs are covered in send in spec/services/whatsapp/send_on_whatsapp_service_spec.rb
require 'rails_helper'

describe Whatsapp::Providers::Whatsapp360DialogService do
  subject(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  let!(:whatsapp_channel) { create(:channel_whatsapp, sync_templates: false, validate_provider_config: false) }
  let(:response_headers) { { 'Content-Type' => 'application/json' } }
  let(:whatsapp_response) { { messages: [{ id: 'message_id' }] } }

  describe '#sync_templates' do
    context 'when called' do
      it 'clears stale templates when provider returns an empty successful response' do
        whatsapp_channel.update!(message_templates: [{ id: 'stale-template', name: 'stale_template' }])

        stub_request(:get, 'https://waba.360dialog.io/v1/configs/templates')
          .to_return(status: 200, body: { waba_templates: [] }.to_json, headers: response_headers)

        subject.sync_templates

        expect(whatsapp_channel.reload.message_templates).to eq([])
      end

      it 'updates message_templates_last_updated even when template request fails' do
        stub_request(:get, 'https://waba.360dialog.io/v1/configs/templates')
          .to_return(status: 401)

        timstamp = whatsapp_channel.reload.message_templates_last_updated
        subject.sync_templates
        expect(whatsapp_channel.reload.message_templates_last_updated).not_to eq(timstamp)
      end
    end
  end

  describe '#send_interactive message' do
    context 'when called' do
      it 'calls message endpoints with button payload when number of items is less than or equal to 3' do
        message = create(:message, message_type: :outgoing, content: 'test',
                                   inbox: whatsapp_channel.inbox, content_type: 'input_select',
                                   content_attributes: {
                                     items: [
                                       { title: 'Burito', value: 'Burito' },
                                       { title: 'Pasta', value: 'Pasta' },
                                       { title: 'Sushi', value: 'Sushi' }
                                     ]
                                   })
        stub_request(:post, 'https://waba.360dialog.io/v1/messages')
          .with(
            body: {
              to: '+123456789',
              interactive: {
                type: 'button',
                body: {
                  text: 'test'
                },
                action: {
                  buttons: [
                    { type: 'reply', reply: { id: 'Burito', title: 'Burito' } },
                    { type: 'reply', reply: { id: 'Pasta', title: 'Pasta' } },
                    { type: 'reply', reply: { id: 'Sushi', title: 'Sushi' } }
                  ]
                }
              }, type: 'interactive'
            }.to_json
          ).to_return(status: 200, body: whatsapp_response.to_json, headers: response_headers)
        expect(HTTParty).to receive(:post)
          .with('https://waba.360dialog.io/v1/messages', hash_including(timeout: 20))
          .and_call_original
        expect(service.send_message('+123456789', message)).to eq 'message_id'
      end

      it 'calls message endpoints with list payload when number of items is greater than 3' do
        items = %w[Burito Pasta Sushi Salad].map { |i| { title: i, value: i } }
        message = create(:message, message_type: :outgoing, content: 'test', inbox: whatsapp_channel.inbox,
                                   content_type: 'input_select', content_attributes: { items: items })

        expected_action = {
          button: I18n.t('conversations.messages.whatsapp.list_button_label'),
          sections: [{ rows: %w[Burito Pasta Sushi Salad].map { |i| { id: i, title: i } } }]
        }

        stub_request(:post, 'https://waba.360dialog.io/v1/messages')
          .with(
            body: {
              to: '+123456789',
              interactive: {
                type: 'list',
                body: {
                  text: 'test'
                },
                action: expected_action
              },
              type: 'interactive'
            }.to_json
          ).to_return(status: 200, body: whatsapp_response.to_json, headers: response_headers)
        expect(service.send_message('+123456789', message)).to eq 'message_id'
      end
    end
  end

  describe 'ambiguous delivery outcomes' do
    let(:message) do
      create(:message, message_type: :outgoing, content: 'test', inbox: whatsapp_channel.inbox)
    end

    it 'records a timeout and suppresses a duplicate send' do
      request = stub_request(:post, 'https://waba.360dialog.io/v1/messages').to_timeout

      expect(service.send_message('+123****6789', message)).to be_nil
      expect(message.reload).to have_attributes(status: 'sent', source_id: nil, external_error: nil)
      expect(message.content_attributes).to include(
        described_class::DELIVERY_OUTCOME_UNKNOWN_KEY => true,
        'whatsapp_360_delivery_outcome_error_class' => 'Net::OpenTimeout'
      )

      expect(service.send_message('+123****6789', message)).to be_nil
      expect(request).to have_been_requested.once
    end

    it 'records a successful response without an acknowledgement as unknown' do
      stub_request(:post, 'https://waba.360dialog.io/v1/messages')
        .to_return(status: 200, body: {}.to_json, headers: response_headers)

      expect(service.send_message('+123****6789', message)).to be_nil
      expect(message.reload.content_attributes).to include(
        described_class::DELIVERY_OUTCOME_UNKNOWN_KEY => true,
        'whatsapp_360_delivery_outcome_error_class' =>
          'Whatsapp::Providers::BaseService::DeliveryAcknowledgementMissingError'
      )
    end
  end
end
