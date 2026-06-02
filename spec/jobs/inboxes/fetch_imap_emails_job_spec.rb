require 'rails_helper'

RSpec.describe Inboxes::FetchImapEmailsJob do
  include ActiveJob::TestHelper
  include ActionMailbox::TestHelper

  let(:account) { create(:account) }
  let(:imap_email_channel) { create(:channel_email, :imap_email, account: account) }
  let(:channel_with_imap_disabled) { create(:channel_email, :imap_email, imap_enabled: false, account: account) }
  let(:microsoft_imap_email_channel) { create(:channel_email, :microsoft_email) }

  describe '#perform' do
    it 'enqueues the job' do
      expect do
        described_class.perform_later(imap_email_channel, 1)
      end.to have_enqueued_job(described_class).on_queue('scheduled_jobs')
    end

    context 'when IMAP is disabled' do
      it 'does not fetch emails' do
        expect(Imap::FetchEmailService).not_to receive(:new)
        expect(Imap::MicrosoftFetchEmailService).not_to receive(:new)
        described_class.perform_now(channel_with_imap_disabled)
      end
    end

    context 'when IMAP reauthorization is required' do
      it 'does not fetch emails' do
        10.times do
          imap_email_channel.authorization_error!
        end

        expect(Imap::FetchEmailService).not_to receive(:new)
        # Confirm the imap_enabled flag is true to avoid false positives.
        expect(imap_email_channel.imap_enabled?).to be true

        described_class.perform_now(imap_email_channel)
      end
    end

    context 'when the channel is regular imap' do
      it 'calls the imap fetch service' do
        fetch_service = double
        allow(Imap::FetchEmailService).to receive(:new).with(channel: imap_email_channel, interval: 1).and_return(fetch_service)
        allow(fetch_service).to receive(:perform).and_return([])

        described_class.perform_now(imap_email_channel)
        expect(fetch_service).to have_received(:perform)
      end

      it 'calls the imap fetch service with the correct interval' do
        fetch_service = double
        allow(Imap::FetchEmailService).to receive(:new).with(channel: imap_email_channel, interval: 4).and_return(fetch_service)
        allow(fetch_service).to receive(:perform).and_return([])

        described_class.perform_now(imap_email_channel, 4)
        expect(fetch_service).to have_received(:perform)
      end
    end

    context 'when the channel is Microsoft' do
      it 'calls the Microsoft fetch service' do
        fetch_service = double
        allow(Imap::MicrosoftFetchEmailService).to receive(:new).with(channel: microsoft_imap_email_channel, interval: 1).and_return(fetch_service)
        allow(fetch_service).to receive(:perform).and_return([])

        described_class.perform_now(microsoft_imap_email_channel)
        expect(fetch_service).to have_received(:perform)
      end
    end

    context 'when IMAP OAuth errors out' do
      it 'marks the connection as requiring authorization' do
        error_response = double
        oauth_error = OAuth2::Error.new(error_response)

        allow(Imap::MicrosoftFetchEmailService).to receive(:new)
          .with(channel: microsoft_imap_email_channel, interval: 1)
          .and_raise(oauth_error)

        allow(Redis::Alfred).to receive(:incr)

        expect(Redis::Alfred).to receive(:incr)
          .with("AUTHORIZATION_ERROR_COUNT:channel_email:#{microsoft_imap_email_channel.id}")

        described_class.perform_now(microsoft_imap_email_channel)
      end

      it 'prompts reauthorization when the refresh token is missing' do
        allow(Imap::MicrosoftFetchEmailService).to receive(:new)
          .with(channel: microsoft_imap_email_channel, interval: 1)
          .and_raise(BaseRefreshOauthTokenService::MissingRefreshTokenError, 'A refresh_token is not available')

        expect(microsoft_imap_email_channel).to receive(:prompt_reauthorization!)

        described_class.perform_now(microsoft_imap_email_channel)
      end
    end

    context 'when the fetch service returns the email objects' do
      let(:inbound_mail) {  create_inbound_email_from_fixture('welcome.eml').mail }
      let(:problematic_mail) { instance_double(Mail::Message, message_id: 'problematic-message-id', from: 'bad@example.com') }
      let(:missing_message_id_mail) do
        instance_double(Mail::Message, message_id: nil, from: 'bad@example.com', to: 'inbox@example.com', subject: 'Broken mail', date: Time.zone.now)
      end
      let(:next_mail) { instance_double(Mail::Message, message_id: 'next-message-id', from: 'next@example.com') }
      let(:mailbox) { double }
      let(:exception_tracker) { double }
      let(:fetch_service) { double }

      before do
        clear_problematic_email_cache
        allow(Imap::ImapMailbox).to receive(:new).and_return(mailbox)
        allow(ChatwootExceptionTracker).to receive(:new).and_return(exception_tracker)
        allow(exception_tracker).to receive(:capture_exception)

        allow(Imap::FetchEmailService).to receive(:new).with(channel: imap_email_channel, interval: 1).and_return(fetch_service)
        allow(fetch_service).to receive(:perform).and_return([inbound_mail])
      end

      it 'calls the mailbox to create emails' do
        allow(mailbox).to receive(:process)

        expect(Imap::FetchEmailService).to receive(:new).with(channel: imap_email_channel, interval: 1).and_return(fetch_service)
        expect(fetch_service).to receive(:perform).and_return([inbound_mail])
        expect(mailbox).to receive(:process).with(inbound_mail, imap_email_channel)

        described_class.perform_now(imap_email_channel)
      end

      it 'logs errors if mailbox returns errors' do
        allow(mailbox).to receive(:process).and_raise(StandardError)

        expect(exception_tracker).to receive(:capture_exception)

        described_class.perform_now(imap_email_channel)
      end

      it 'records a timed out email and continues processing the next email' do
        allow(fetch_service).to receive(:perform).and_return([problematic_mail, next_mail])
        allow(mailbox).to receive(:process) do |mail, _channel|
          raise Timeout::Error if mail.message_id == problematic_mail.message_id
        end

        described_class.perform_now(imap_email_channel)

        expect(mailbox).to have_received(:process).with(problematic_mail, imap_email_channel)
        expect(mailbox).to have_received(:process).with(next_mail, imap_email_channel)
        expect(Redis::Alfred.get(problematic_email_cache_key(problematic_mail)).to_i).to eq(1)
      end

      it 'records a timed out email without a message id' do
        allow(fetch_service).to receive(:perform).and_return([missing_message_id_mail])
        allow(mailbox).to receive(:process).and_raise(Timeout::Error)

        described_class.perform_now(imap_email_channel)

        cache_keys = problematic_email_cache_keys
        expect(cache_keys.length).to eq(1)
        expect(Redis::Alfred.get(cache_keys.first).to_i).to eq(1)
      end

      it 'skips repeatedly failing emails and continues processing the next email' do
        Redis::Alfred.setex(problematic_email_cache_key(problematic_mail), described_class::PROBLEMATIC_EMAIL_FAILURE_THRESHOLD, 1.day)
        allow(fetch_service).to receive(:perform).and_return([problematic_mail, next_mail])
        allow(mailbox).to receive(:process)

        described_class.perform_now(imap_email_channel)

        expect(mailbox).not_to have_received(:process).with(problematic_mail, imap_email_channel)
        expect(mailbox).to have_received(:process).with(next_mail, imap_email_channel)
      end

      it 'clears the failure marker when a previously failing email is processed successfully' do
        Redis::Alfred.setex(problematic_email_cache_key(problematic_mail), 1, 1.day)
        allow(fetch_service).to receive(:perform).and_return([problematic_mail])
        allow(mailbox).to receive(:process)

        described_class.perform_now(imap_email_channel)

        expect(Redis::Alfred.get(problematic_email_cache_key(problematic_mail))).to be_nil
      end

      def problematic_email_cache_key(mail)
        "imap:problematic-email:#{imap_email_channel.id}:#{Digest::SHA256.hexdigest(mail.message_id)}"
      end

      def problematic_email_cache_keys
        Redis::Alfred.scan_each(match: "imap:problematic-email:#{imap_email_channel.id}:*").to_a
      end

      def clear_problematic_email_cache
        problematic_email_cache_keys.each { |key| Redis::Alfred.delete(key) }
      end
    end
  end
end
