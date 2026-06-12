# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join 'spec/models/concerns/reauthorizable_shared.rb'

RSpec.describe Channel::Instagram do
  let(:channel) { create(:channel_instagram) }

  it { is_expected.to validate_presence_of(:account_id) }
  it { is_expected.to validate_presence_of(:access_token) }
  it { is_expected.to validate_presence_of(:instagram_id) }
  it { is_expected.to belong_to(:account) }
  it { is_expected.to have_one(:inbox).dependent(:destroy_async) }

  it 'has a valid name' do
    expect(channel.name).to eq('Instagram')
  end

  describe '#subscribe' do
    before do
      stub_request(:post, /graph.instagram.com/)
    end

    it 'redacts access tokens from rescued subscription error logs' do
      instagram_channel = build(:channel_instagram, access_token: 'stored-token', instagram_id: '12345')
      messages = []

      allow(HTTParty).to receive(:post)
        .and_raise(StandardError, 'failed access_token=explicit-token')
      allow(Rails.logger).to receive(:debug) { |&block| messages << block.call }

      expect(instagram_channel.subscribe(access_token: 'explicit-token')).to be true
      expect(messages.join).to include('[FILTERED]')
      expect(messages.join).not_to include('explicit-token')
    end

    it 'raises only a redacted error message for strict subscription failures' do
      instagram_channel = build(:channel_instagram, access_token: 'stored-token', instagram_id: '12345')
      allow(HTTParty).to receive(:post)
        .and_raise(StandardError, 'failed access_token=explicit-token')

      expect { instagram_channel.subscribe(raise_on_error: true, access_token: 'explicit-token') }.to raise_error(StandardError) do |error|
        expect(error.message).to include('[FILTERED]')
        expect(error.message).not_to include('explicit-token')
      end
    end
  end

  describe 'concerns' do
    before do
      allow(Meta::AuthorizationHealthCheckService).to receive(:new)
        .and_return(instance_double(Meta::AuthorizationHealthCheckService, healthy?: false))
    end

    it_behaves_like 'reauthorizable'

    it 'does not prompt reauthorization when a live Meta health-check still passes' do
      health_check = instance_double(Meta::AuthorizationHealthCheckService, healthy?: true)
      allow(Meta::AuthorizationHealthCheckService).to receive(:new).with(channel).and_return(health_check)
      expect(AdministratorNotifications::ChannelNotificationsMailer).not_to receive(:with)

      channel.authorization_error!

      expect(channel.reauthorization_required?).to be(false)
      expect(channel.authorization_error_count).to eq(0)
    end

    context 'when prompt_reauthorization!' do
      it 'calls channel notifier mail for instagram' do
        admin_mailer = double
        mailer_double = double

        expect(AdministratorNotifications::ChannelNotificationsMailer).to receive(:with).and_return(admin_mailer)
        expect(admin_mailer).to receive(:instagram_disconnect).with(channel.inbox).and_return(mailer_double)
        expect(mailer_double).to receive(:deliver_later)

        channel.prompt_reauthorization!
      end
    end
  end
end
