# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join 'spec/models/concerns/reauthorizable_shared.rb'

RSpec.describe Channel::FacebookPage do
  before do
    stub_request(:post, /graph.facebook.com/)
  end

  let(:channel) { create(:channel_facebook_page) }

  it { is_expected.to validate_presence_of(:account_id) }
  # it { is_expected.to validate_uniqueness_of(:page_id).scoped_to(:account_id) }
  it { is_expected.to belong_to(:account) }
  it { is_expected.to have_one(:inbox).dependent(:destroy_async) }

  describe 'concerns' do
    it_behaves_like 'reauthorizable'

    context 'when prompt_reauthorization!' do
      it 'calls channel notifier mail for facebook' do
        admin_mailer = double
        mailer_double = double

        expect(AdministratorNotifications::ChannelNotificationsMailer).to receive(:with).and_return(admin_mailer)
        expect(admin_mailer).to receive(:facebook_disconnect).with(channel.inbox).and_return(mailer_double)
        expect(mailer_double).to receive(:deliver_later)

        channel.prompt_reauthorization!
      end
    end
  end

  it 'has a valid name' do
    expect(channel.name).to eq('Facebook')
  end

  describe '#subscribe' do
    it 'redacts tokens from rescued subscription error logs' do
      page = build(
        :channel_facebook_page,
        page_access_token: 'page-secret-token',
        user_access_token: 'user-secret-token'
      )
      messages = []

      allow(Facebook::Messenger::Subscriptions).to receive(:subscribe)
        .and_raise(StandardError, 'failed access_token=page-secret-token user-secret-token')
      allow(Rails.logger).to receive(:debug) { |&block| messages << block.call }

      expect(page.subscribe).to be true
      expect(messages.join).to include('[FILTERED]')
      expect(messages.join).not_to include('page-secret-token')
      expect(messages.join).not_to include('user-secret-token')
    end

    it 'raises only a redacted error message for strict subscription failures' do
      page = build(
        :channel_facebook_page,
        page_access_token: 'page-secret-token',
        user_access_token: 'user-secret-token'
      )
      allow(Facebook::Messenger::Subscriptions).to receive(:subscribe)
        .and_raise(StandardError, 'failed access_token=page-secret-token user-secret-token')

      expect { page.subscribe(raise_on_error: true) }.to raise_error(StandardError) do |error|
        expect(error.message).to include('[FILTERED]')
        expect(error.message).not_to include('page-secret-token')
        expect(error.message).not_to include('user-secret-token')
      end
    end
  end
end
