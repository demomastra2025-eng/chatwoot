require 'rails_helper'

describe Webhooks::Trigger do
  include ActiveJob::TestHelper

  subject(:trigger) { described_class }

  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:conversation) { create(:conversation, inbox: inbox) }
  let!(:message) { create(:message, account: account, inbox: inbox, conversation: conversation) }

  let(:webhook_type) { :api_inbox_webhook }
  let(:url) { 'https://webhook.example.com/events' }
  let(:agent_bot_error_content) { I18n.t('conversations.activity.agent_bot.error_moved_to_open') }
  let(:default_timeout) { 5 }
  let(:webhook_timeout) { default_timeout }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(GlobalConfig).to receive(:get_value).and_call_original
    allow(GlobalConfig).to receive(:get_value).with('WEBHOOK_TIMEOUT').and_return(webhook_timeout)
    allow(GlobalConfig).to receive(:get_value).with('DEPLOYMENT_ENV').and_return(nil)
  end

  after do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def expect_safe_fetch(payload:, headers:, error: nil, timeout: webhook_timeout.presence&.to_i&.positive? ? webhook_timeout.to_i : default_timeout)
    expectation = expect(SafeFetch).to receive(:fetch).with(
      url,
      method: :post,
      body: payload.to_json,
      headers: headers,
      open_timeout: timeout,
      read_timeout: timeout,
      validate_content_type: false
    )
    error ? expectation.and_raise(error) : expectation.and_yield(nil)
  end

  describe '#execute' do
    it 'triggers webhook through SafeFetch instead of raw RestClient' do
      payload = { hello: :hello }
      expect(RestClient::Request).not_to receive(:execute)
      expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' })

      trigger.execute(url, payload, webhook_type)
    end

    it 'passes private-network allowlist only for API inbox webhooks' do
      payload = { hello: :hello }

      with_modified_env API_INBOX_WEBHOOK_PRIVATE_NETWORK_ALLOWED_HOSTS: 'internal-webhook.example.com, 10.0.0.5' do
        expect(SafeFetch).to receive(:fetch).with(
          url,
          method: :post,
          body: payload.to_json,
          headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' },
          open_timeout: webhook_timeout,
          read_timeout: webhook_timeout,
          validate_content_type: false,
          private_network_allowed_hosts: ['internal-webhook.example.com', '10.0.0.5']
        ).and_yield(nil)

        trigger.execute(url, payload, :api_inbox_webhook)
      end
    end

    it 'does not pass private-network allowlist for agent bot webhooks' do
      payload = { hello: :hello }

      with_modified_env API_INBOX_WEBHOOK_PRIVATE_NETWORK_ALLOWED_HOSTS: 'internal-webhook.example.com' do
        expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' })

        trigger.execute(url, payload, :agent_bot_webhook)
      end
    end

    it 'raises retryable API inbox errors without failing a message immediately' do
      payload = { event: 'message_created', conversation: { id: conversation.id }, id: message.id }
      error = SafeFetch::HttpError.new('500 Internal Server Error')
      expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, error: error)

      expect { trigger.execute(url, payload, webhook_type) }.to raise_error(Webhooks::Trigger::RetryableError) do |raised|
        expect(raised.status).to eq(500)
      end
      expect(message.reload.status).to eq('sent')
    end

    it 'retries API inbox network failures' do
      payload = { event: 'message_updated', conversation: { id: conversation.id }, id: message.id }
      error = SafeFetch::FetchError.new('network failure')
      expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, error: error)

      expect { trigger.execute(url, payload, webhook_type) }.to raise_error(Webhooks::Trigger::RetryableError) do |raised|
        expect(raised.status).to be_nil
      end
      expect(message.reload.status).to eq('sent')
    end

    context 'when webhook type is agent bot' do
      let(:webhook_type) { :agent_bot_webhook }
      let!(:pending_conversation) { create(:conversation, inbox: inbox, status: :pending, account: account) }
      let!(:pending_message) { create(:message, account: account, inbox: inbox, conversation: pending_conversation) }

      it 'raises retryable 500 errors and does not reopen conversation immediately' do
        payload = { event: 'message_created', id: pending_message.id }
        error = SafeFetch::HttpError.new('500 Internal Server Error')
        expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, error: error)

        expect { trigger.execute(url, payload, webhook_type) }.to raise_error(Webhooks::Trigger::RetryableError) do |raised|
          expect(raised.status).to eq(500)
        end
        expect(pending_conversation.reload.status).to eq('pending')
        expect(Conversations::ActivityMessageJob).not_to have_been_enqueued
      end

      it 'raises retryable 429 errors and does not reopen conversation immediately' do
        payload = { event: 'message_created', id: pending_message.id }
        error = SafeFetch::HttpError.new('429 Too Many Requests')
        expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, error: error)

        expect { trigger.execute(url, payload, webhook_type) }.to raise_error(Webhooks::Trigger::RetryableError) do |raised|
          expect(raised.status).to eq(429)
        end
        expect(pending_conversation.reload.status).to eq('pending')
        expect(Conversations::ActivityMessageJob).not_to have_been_enqueued
      end

      it 'reopens conversation and enqueues activity message for non-retryable failures when pending' do
        payload = { event: 'message_created', id: pending_message.id }
        error = SafeFetch::FetchError.new('network failure')
        expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, error: error)

        expect do
          perform_enqueued_jobs do
            trigger.execute(url, payload, webhook_type)
          end
        end.not_to(change { pending_message.reload.status })

        expect(pending_conversation.reload.status).to eq('open')

        activity_message = pending_conversation.reload.messages.order(:created_at).last
        expect(activity_message.message_type).to eq('activity')
        expect(activity_message.content).to eq(agent_bot_error_content)
      end

      it 'does not change message status or enqueue activity when conversation is not pending' do
        payload = { event: 'message_created', conversation: { id: conversation.id }, id: message.id }
        error = SafeFetch::FetchError.new('network failure')
        expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, error: error)

        expect do
          trigger.execute(url, payload, webhook_type)
        end.not_to(change { message.reload.status })

        expect(Conversations::ActivityMessageJob).not_to have_been_enqueued
        expect(conversation.reload.status).to eq('open')
      end

      it 'keeps conversation pending when keep_pending_on_bot_failure setting is enabled' do
        account.update(keep_pending_on_bot_failure: true)
        payload = { event: 'message_created', id: pending_message.id }
        error = SafeFetch::FetchError.new('network failure')
        expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, error: error)

        trigger.execute(url, payload, webhook_type)

        expect(Conversations::ActivityMessageJob).not_to have_been_enqueued
        expect(pending_conversation.reload.status).to eq('pending')
      end
    end

    it 'fails fast for non-retryable API inbox errors' do
      payload = { event: 'message_created', conversation: { id: conversation.id }, id: message.id }
      error = SafeFetch::HttpError.new('400 Bad Request')
      expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, error: error)

      expect { trigger.execute(url, payload, webhook_type) }.not_to raise_error
      expect(message.reload.status).to eq('failed')
    end

    it 'does not rewrite an already failed message after a message-updated webhook failure' do
      message.update!(status: :failed, external_error: 'original failure')
      original_updated_at = message.reload.updated_at
      payload = { event: 'message_updated', conversation: { id: conversation.id }, id: message.id }
      error = SafeFetch::HttpError.new('400 Bad Request')

      described_class.new(url, payload, webhook_type).handle_failure(error)

      expect(message.reload.updated_at).to eq(original_updated_at)
      expect(message.external_error).to eq('original failure')
    end

    it 'retries failures for other API inbox events without changing message status' do
      payload = { event: 'conversation_created', conversation: { id: conversation.id }, id: message.id }
      error = SafeFetch::FetchError.new('network failure')
      expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, error: error)

      expect { trigger.execute(url, payload, webhook_type) }.to raise_error(Webhooks::Trigger::RetryableError)
      expect(message.reload.status).to eq('sent')
    end
  end

  describe 'request headers' do
    let(:payload) { { event: 'message_created' } }
    let(:body) { payload.to_json }

    it 'sends only JSON content negotiation headers without secret or delivery_id' do
      expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' })

      trigger.execute(url, payload, webhook_type)
    end

    it 'adds X-Chatwoot-Delivery header' do
      expect_safe_fetch(
        payload: payload,
        headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json', 'X-Chatwoot-Delivery' => 'test-uuid' }
      )

      trigger.execute(url, payload, webhook_type, delivery_id: 'test-uuid')
    end

    it 'adds X-Chatwoot-Timestamp and X-Chatwoot-Signature headers with timestamp.body HMAC' do
      secret = '[REDACTED]'
      expect(SafeFetch).to receive(:fetch) do |_url, options|
        headers = options[:headers]
        ts = headers['X-Chatwoot-Timestamp']
        expect(ts).to match(/\A\d+\z/)
        expected_sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{ts}.#{body}")}"
        wrong_sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
        expect(headers['X-Chatwoot-Signature']).to eq(expected_sig)
        expect(headers['X-Chatwoot-Signature']).not_to eq(wrong_sig)
      end.and_yield(nil)

      trigger.execute(url, payload, webhook_type, secret: secret)
    end

    it 'includes delivery, timestamp, and signature together' do
      expect(SafeFetch).to receive(:fetch) do |_url, options|
        headers = options[:headers]
        expect(headers['X-Chatwoot-Delivery']).to eq('abc-123')
        expect(headers['X-Chatwoot-Timestamp']).to be_present
        expect(headers['X-Chatwoot-Signature']).to start_with('sha256=')
      end.and_yield(nil)

      trigger.execute(url, payload, webhook_type, secret: '[REDACTED]', delivery_id: 'abc-123')
    end
  end

  context 'when webhook timeout configuration is blank' do
    let(:webhook_timeout) { nil }

    it 'falls back to default timeout' do
      payload = { hello: :hello }
      expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, timeout: default_timeout)

      trigger.execute(url, payload, webhook_type)
    end
  end

  context 'when webhook timeout configuration is invalid' do
    let(:webhook_timeout) { -1 }

    it 'falls back to default timeout' do
      payload = { hello: :hello }
      expect_safe_fetch(payload: payload, headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }, timeout: default_timeout)

      trigger.execute(url, payload, webhook_type)
    end
  end
end
