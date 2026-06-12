require 'rails_helper'

describe Whatsapp::Providers::WhatsappCloudService do
  subject(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  let(:api_version) { 'v22.0' }
  let(:conversation) { create(:conversation, inbox: whatsapp_channel.inbox) }
  let(:whatsapp_channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false) }

  let(:message) do
    create(:message, conversation: conversation, message_type: :outgoing, content: 'test', inbox: whatsapp_channel.inbox, source_id: 'external_id')
  end

  let(:message_with_reply) do
    create(:message, conversation: conversation, message_type: :outgoing, content: 'reply', inbox: whatsapp_channel.inbox,
                     content_attributes: { in_reply_to: message.id })
  end

  let(:response_headers) { { 'Content-Type' => 'application/json' } }
  let(:whatsapp_response) { { messages: [{ id: 'message_id' }] } }

  before do
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v22.0').and_return(api_version)
    stub_request(:get, "https://graph.facebook.com/#{api_version}/123456789/message_templates")
  end

  describe '#send_message' do
    context 'when called' do
      it 'calls message endpoints for normal messages' do
        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .with(
            body: {
              messaging_product: 'whatsapp',
              context: nil,
              to: '+123456789',
              text: { body: message.content },
              type: 'text'
            }.to_json
          )
          .to_return(status: 200, body: whatsapp_response.to_json, headers: response_headers)
        expect(service.send_message('+123456789', message)).to eq 'message_id'
      end

      it 'calls message endpoints for a reply to messages' do
        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .with(
            body: {
              messaging_product: 'whatsapp',
              context: {
                message_id: message.source_id
              },
              to: '+123****6789',
              text: { body: message_with_reply.content },
              type: 'text'
            }.to_json
          )
          .to_return(status: 200, body: whatsapp_response.to_json, headers: response_headers)
        expect(service.send_message('+123****6789', message_with_reply)).to eq 'message_id'
      end

      it 'marks the channel for reauthorization when Meta returns an invalid token error' do
        allow(Meta::AuthorizationHealthCheckService).to receive(:new)
          .with(whatsapp_channel)
          .and_return(instance_double(Meta::AuthorizationHealthCheckService, healthy?: false))

        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .to_return(
            status: 401,
            body: {
              error: {
                message: 'Error validating access token: Session has expired',
                type: 'OAuthException',
                code: 190,
                fbtrace_id: 'trace-190'
              }
            }.to_json,
            headers: response_headers
          )

        expect(service.send_message('+123****6789', message)).to be_nil

        expect(message.reload.status).to eq('failed')
        expect(message.external_error).to include('Error validating access token')
        expect(whatsapp_channel.reload.reauthorization_required?).to be(true)
        expect(whatsapp_channel.provider_config).to include(
          'authorization_status' => 'reauthorization_required',
          'authorization_error' => hash_including(
            'code' => 190,
            'type' => 'OAuthException',
            'message' => include('Error validating access token')
          )
        )
      end

      it 'schedules a retry and keeps the message pending when Meta returns API unknown' do
        message.update!(source_id: nil)

        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .to_return(
            status: 500,
            body: {
              error: {
                message: 'An unknown error has occurred',
                type: 'OAuthException',
                code: 1,
                fbtrace_id: 'trace-1'
              }
            }.to_json,
            headers: response_headers
          )

        expect do
          expect(service.send_message('+123****6789', message)).to be_nil
        end.to have_enqueued_job(SendReplyJob).with(message.id).on_queue('outbound_messages')

        expect(message.reload.status).to eq('sent')
        expect(message.external_error).to be_nil
        expect(message.content_attributes).to include(
          'whatsapp_cloud_send_retry_count' => 1,
          'whatsapp_cloud_send_retry_error_code' => 1,
          'whatsapp_cloud_send_retry_error_message' => 'An unknown error has occurred'
        )
      end

      it 'marks the message failed after WhatsApp Cloud transient retries are exhausted' do
        message.update!(
          source_id: nil,
          content_attributes: { 'whatsapp_cloud_send_retry_count' => 3 }
        )

        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .to_return(
            status: 500,
            body: {
              error: {
                message: 'Message failed to send due to an unknown error.',
                type: 'OAuthException',
                code: 131_000,
                fbtrace_id: 'trace-131000'
              }
            }.to_json,
            headers: response_headers
          )

        expect do
          expect(service.send_message('+123****6789', message)).to be_nil
        end.not_to have_enqueued_job(SendReplyJob)

        expect(message.reload.status).to eq('failed')
        expect(message.external_error).to include('Message failed to send due to an unknown error')
      end

      it 'clears WhatsApp Cloud transient retry metadata after a successful retry' do
        message.update!(
          source_id: nil,
          content_attributes: {
            'whatsapp_cloud_send_retry_count' => 1,
            'whatsapp_cloud_send_retry_error_code' => 1,
            'whatsapp_cloud_send_retry_error_message' => 'An unknown error has occurred',
            'whatsapp_cloud_send_retry_next_at' => 1.minute.from_now.iso8601,
            'external_error' => 'An unknown error has occurred'
          }
        )

        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .to_return(status: 200, body: whatsapp_response.to_json, headers: response_headers)

        expect(service.send_message('+123****6789', message)).to eq('message_id')

        expect(message.reload.external_error).to be_nil
        expect(message.content_attributes.keys).not_to include(
          'whatsapp_cloud_send_retry_count',
          'whatsapp_cloud_send_retry_error_code',
          'whatsapp_cloud_send_retry_error_message',
          'whatsapp_cloud_send_retry_next_at'
        )
      end

      it 'calls message endpoints for image attachment message messages' do
        attachment = message.attachments.new(account_id: message.account_id, file_type: :image)
        attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')

        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .with(
            body: hash_including({
                                   messaging_product: 'whatsapp',
                                   to: '+123456789',
                                   type: 'image',
                                   image: WebMock::API.hash_including({ caption: message.content, link: anything })
                                 })
          )
          .to_return(status: 200, body: whatsapp_response.to_json, headers: response_headers)
        expect(service.send_message('+123456789', message)).to eq 'message_id'
      end

      it 'calls message endpoints for document attachment message messages' do
        attachment = message.attachments.new(account_id: message.account_id, file_type: :file)
        attachment.file.attach(io: Rails.root.join('spec/assets/sample.pdf').open, filename: 'sample.pdf', content_type: 'application/pdf')

        # ref: https://github.com/bblimke/webmock/issues/900
        # reason for Webmock::API.hash_including
        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .with(
            body: hash_including({
                                   messaging_product: 'whatsapp',
                                   to: '+123456789',
                                   type: 'document',
                                   document: WebMock::API.hash_including({ filename: 'sample.pdf', caption: message.content, link: anything })
                                 })
          )
          .to_return(status: 200, body: whatsapp_response.to_json, headers: response_headers)
        expect(service.send_message('+123456789', message)).to eq 'message_id'
      end
    end
  end

  describe 'call action methods' do
    let(:calls_url) { "https://graph.facebook.com/#{api_version}/123456789/calls" }
    let(:messages_url) { "https://graph.facebook.com/#{api_version}/123456789/messages" }

    it 'POSTs pre_accept with an SDP answer' do
      stub_request(:post, calls_url)
        .with(body: {
          messaging_product: 'whatsapp',
          call_id: 'WACALL',
          action: 'pre_accept',
          session: { sdp: 'sdp_answer', sdp_type: 'answer' }
        }.to_json)
        .to_return(status: 200, body: '{}', headers: response_headers)

      expect(service.pre_accept_call('WACALL', 'sdp_answer')).to be true
    end

    it 'POSTs accept with an SDP answer' do
      stub_request(:post, calls_url)
        .with(body: {
          messaging_product: 'whatsapp',
          call_id: 'WACALL',
          action: 'accept',
          session: { sdp: 'sdp_answer', sdp_type: 'answer' }
        }.to_json)
        .to_return(status: 200, body: '{}', headers: response_headers)

      expect(service.accept_call('WACALL', 'sdp_answer')).to be true
    end

    it 'POSTs reject and returns false on Meta failure' do
      stub_request(:post, calls_url)
        .with(body: { messaging_product: 'whatsapp', call_id: 'WACALL', action: 'reject' }.to_json)
        .to_return(status: 400, body: '{}', headers: response_headers)

      expect(service.reject_call('WACALL')).to be false
    end

    it 'POSTs terminate' do
      stub_request(:post, calls_url)
        .with(body: { messaging_product: 'whatsapp', call_id: 'WACALL', action: 'terminate' }.to_json)
        .to_return(status: 200, body: '{}', headers: response_headers)

      expect(service.terminate_call('WACALL')).to be true
    end

    it 'sends a call permission request interactive message' do
      stub_request(:post, messages_url)
        .with(body: hash_including(messaging_product: 'whatsapp', to: '15551234567', type: 'interactive'))
        .to_return(status: 200, body: { messages: [{ id: 'wamid.permission' }] }.to_json, headers: response_headers)

      expect(service.send_call_permission_request('15551234567')).to eq('messages' => [{ 'id' => 'wamid.permission' }])
    end

    it 'initiates outbound calls with connect action and SDP offer' do
      stub_request(:post, calls_url)
        .with(body: {
          messaging_product: 'whatsapp',
          to: '15551234567',
          action: 'connect',
          session: { sdp: 'sdp_offer', sdp_type: 'offer' }
        }.to_json)
        .to_return(status: 200, body: { calls: [{ id: 'wacall_1' }] }.to_json, headers: response_headers)

      expect(service.initiate_call('15551234567', 'sdp_offer')).to eq('calls' => [{ 'id' => 'wacall_1' }])
    end

    it 'maps Meta error 138006 to NoCallPermission' do
      stub_request(:post, calls_url)
        .to_return(status: 400, body: { error: { code: '138006', error_user_msg: 'No call permission' } }.to_json, headers: response_headers)

      expect { service.initiate_call('15551234567', 'sdp_offer') }
        .to raise_error(Whatsapp::CallErrors::NoCallPermission, 'No call permission')
    end

    it 'maps non-permission errors with malformed bodies to CallFailed' do
      stub_request(:post, calls_url)
        .to_return(status: 502, body: '<html>502 Bad Gateway</html>', headers: { 'Content-Type' => 'text/html' })

      expect { service.initiate_call('15551234567', 'sdp_offer') }
        .to raise_error(Whatsapp::CallErrors::CallFailed, 'Failed to initiate call')
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
        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .with(
            body: {
              messaging_product: 'whatsapp', to: '+123456789',
              interactive: {
                type: 'button',
                body: {
                  text: 'test'
                },
                action: '{"buttons":[{"type":"reply","reply":{"id":"Burito","title":"Burito"}},{"type":"reply",' \
                        '"reply":{"id":"Pasta","title":"Pasta"}},{"type":"reply","reply":{"id":"Sushi","title":"Sushi"}}]}'
              }, type: 'interactive'
            }.to_json
          ).to_return(status: 200, body: whatsapp_response.to_json, headers: response_headers)
        expect(service.send_message('+123456789', message)).to eq 'message_id'
      end

      it 'calls message endpoints with list payload when number of items is greater than 3' do
        items = %w[Burito Pasta Sushi Salad].map { |i| { title: i, value: i } }
        message = create(:message, message_type: :outgoing, content: 'test', inbox: whatsapp_channel.inbox,
                                   content_type: 'input_select', content_attributes: { items: items })

        expected_action = {
          button: I18n.t('conversations.messages.whatsapp.list_button_label'),
          sections: [{ rows: %w[Burito Pasta Sushi Salad].map { |i| { id: i, title: i } } }]
        }.to_json

        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .with(
            body: {
              messaging_product: 'whatsapp', to: '+123456789',
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

  describe '#send_template' do
    let(:template_info) do
      {
        name: 'test_template',
        namespace: 'test_namespace',
        lang_code: 'en_US',
        parameters: [{ type: 'text', text: 'test' }]
      }
    end

    let(:template_body) do
      {
        messaging_product: 'whatsapp',
        recipient_type: 'individual', # Added recipient_type field
        to: '+123456789',
        type: 'template',
        template: {
          name: template_info[:name],
          language: {
            policy: 'deterministic',
            code: template_info[:lang_code]
          },
          components: template_info[:parameters] # Changed to use parameters directly (enhanced format)
        }
      }
    end

    context 'when called' do
      it 'calls message endpoints with template params for template messages' do
        stub_request(:post, "https://graph.facebook.com/#{api_version}/123456789/messages")
          .with(
            body: template_body.to_json
          )
          .to_return(status: 200, body: whatsapp_response.to_json, headers: response_headers)

        expect(service.send_template('+123456789', template_info, message)).to eq('message_id')
      end
    end
  end

  describe '#sync_templates' do
    context 'when called' do
      it 'updated the message templates' do
        stub_request(:get, "https://graph.facebook.com/#{api_version}/123456789/message_templates")
          .to_return(
            { status: 200, headers: response_headers,
              body: { data: [
                { id: '123456789', name: 'test_template' }
              ], paging: { next: "https://graph.facebook.com/#{api_version}/123456789/message_templates" } }.to_json },
            { status: 200, headers: response_headers,
              body: { data: [
                { id: '123456789', name: 'next_template' }
              ], paging: { next: "https://graph.facebook.com/#{api_version}/123456789/message_templates" } }.to_json },
            { status: 200, headers: response_headers,
              body: { data: [
                { id: '123456789', name: 'last_template' }
              ], paging: { prev: "https://graph.facebook.com/#{api_version}/123456789/message_templates" } }.to_json }
          )

        timstamp = whatsapp_channel.reload.message_templates_last_updated
        expect(subject.sync_templates).to be(true)
        expect(whatsapp_channel.reload.message_templates.first).to eq({ id: '123456789', name: 'test_template' }.stringify_keys)
        expect(whatsapp_channel.reload.message_templates.second).to eq({ id: '123456789', name: 'next_template' }.stringify_keys)
        expect(whatsapp_channel.reload.message_templates.last).to eq({ id: '123456789', name: 'last_template' }.stringify_keys)
        expect(whatsapp_channel.reload.message_templates_last_updated).not_to eq(timstamp)
      end

      it 'clears stale templates when provider returns an empty successful response' do
        whatsapp_channel.update!(message_templates: [{ id: 'stale-template', name: 'stale_template' }])

        stub_request(:get, "https://graph.facebook.com/#{api_version}/123456789/message_templates")
          .to_return(status: 200, headers: response_headers, body: { data: [] }.to_json)

        subject.sync_templates

        expect(whatsapp_channel.reload.message_templates).to eq([])
      end

      it 'updates message_templates_last_updated even when template request fails' do
        stub_request(:get, "https://graph.facebook.com/#{api_version}/123456789/message_templates")
          .to_return(status: 401)

        timstamp = whatsapp_channel.reload.message_templates_last_updated
        subject.sync_templates
        expect(whatsapp_channel.reload.message_templates_last_updated).not_to eq(timstamp)
      end
    end
  end

  describe '#validate_provider_config' do
    context 'when called' do
      it 'returns true if valid' do
        stub_request(:get, "https://graph.facebook.com/#{api_version}/123456789/message_templates")
        expect(subject.validate_provider_config?).to be(true)
        expect(whatsapp_channel.errors.present?).to be(false)
      end

      it 'returns false if invalid' do
        stub_request(:get, "https://graph.facebook.com/#{api_version}/123456789/message_templates").to_return(status: 401)
        expect(subject.validate_provider_config?).to be(false)
      end
    end
  end

  describe 'Ability to configure Base URL' do
    context 'when environment variable WHATSAPP_CLOUD_BASE_URL is not set' do
      it 'uses the default base url' do
        expect(subject.send(:api_base_path)).to eq('https://graph.facebook.com')
      end
    end

    context 'when environment variable WHATSAPP_CLOUD_BASE_URL is set' do
      it 'uses the base url from the environment variable' do
        with_modified_env WHATSAPP_CLOUD_BASE_URL: 'http://test.com' do
          expect(subject.send(:api_base_path)).to eq('http://test.com')
        end
      end
    end
  end

  describe '#handle_error' do
    let(:error_message) { 'Invalid message format' }
    let(:error_response) do
      {
        'error' => {
          'message' => error_message,
          'code' => 100
        }
      }
    end

    let(:error_response_object) do
      instance_double(
        HTTParty::Response,
        body: error_response.to_json,
        parsed_response: error_response
      )
    end

    before do
      allow(Rails.logger).to receive(:error)
    end

    context 'when there is a message' do
      it 'logs error and updates message status' do
        service.instance_variable_set(:@message, message)
        service.send(:handle_error, error_response_object, message)

        expect(message.reload.status).to eq('failed')
        expect(message.reload.external_error).to eq(error_message)
      end
    end

    context 'when error message is blank' do
      let(:error_response_object) do
        instance_double(
          HTTParty::Response,
          body: '{}',
          parsed_response: {}
        )
      end

      it 'logs error but does not update message' do
        service.instance_variable_set(:@message, message)
        service.send(:handle_error, error_response_object, message)

        expect(message.reload.status).not_to eq('failed')
        expect(message.reload.external_error).to be_nil
      end
    end
  end

  describe 'CSAT template methods' do
    let(:mock_csat_template_service) { instance_double(Whatsapp::CsatTemplateService) }
    let(:expected_template_name) { "customer_satisfaction_survey_#{whatsapp_channel.inbox.id}" }
    let(:template_config) do
      {
        name: expected_template_name,
        language: 'en',
        category: 'UTILITY'
      }
    end

    before do
      allow(Whatsapp::CsatTemplateService).to receive(:new)
        .with(whatsapp_channel)
        .and_return(mock_csat_template_service)
    end

    describe '#create_csat_template' do
      it 'delegates to csat_template_service with correct config' do
        allow(mock_csat_template_service).to receive(:create_template)
          .with(template_config)
          .and_return({ success: true, template_id: '123' })

        result = service.create_csat_template(template_config)

        expect(mock_csat_template_service).to have_received(:create_template).with(template_config)
        expect(result).to eq({ success: true, template_id: '123' })
      end
    end

    describe '#delete_csat_template' do
      it 'delegates to csat_template_service with default template name' do
        allow(mock_csat_template_service).to receive(:delete_template)
          .with(expected_template_name)
          .and_return({ success: true })

        result = service.delete_csat_template

        expect(mock_csat_template_service).to have_received(:delete_template).with(expected_template_name)
        expect(result).to eq({ success: true })
      end

      it 'delegates to csat_template_service with custom template name' do
        custom_template_name = 'custom_csat_template'
        allow(mock_csat_template_service).to receive(:delete_template)
          .with(custom_template_name)
          .and_return({ success: true })

        result = service.delete_csat_template(custom_template_name)

        expect(mock_csat_template_service).to have_received(:delete_template).with(custom_template_name)
        expect(result).to eq({ success: true })
      end
    end

    describe '#get_template_status' do
      it 'delegates to csat_template_service with template name' do
        template_name = 'customer_survey_template'
        expected_response = { success: true, template: { status: 'APPROVED' } }
        allow(mock_csat_template_service).to receive(:get_template_status)
          .with(template_name)
          .and_return(expected_response)

        result = service.get_template_status(template_name)

        expect(mock_csat_template_service).to have_received(:get_template_status).with(template_name)
        expect(result).to eq(expected_response)
      end
    end

    describe 'csat_template_service memoization' do
      it 'creates and memoizes the csat_template_service instance' do
        allow(Whatsapp::CsatTemplateService).to receive(:new)
          .with(whatsapp_channel)
          .and_return(mock_csat_template_service)
        allow(mock_csat_template_service).to receive(:get_template_status)
          .and_return({ success: true })

        # Call multiple methods that use the service
        service.get_template_status('test1')
        service.get_template_status('test2')

        # Verify the service was only instantiated once
        expect(Whatsapp::CsatTemplateService).to have_received(:new).once
      end
    end
  end
end
