require 'rails_helper'

RSpec.describe Channels::LinkedinPersonal::ProcessWebhookEventJob do
  it 'discards a webhook job enqueued by an older release' do
    expect do
      Channels::LinkedinPersonal::ProcessWebhookEventJob.perform_now(1, {})
    end.not_to raise_error
  end

  it 'discards a history webhook job enqueued by an older release' do
    expect do
      Channels::LinkedinPersonal::ProcessHistoryWebhookEventJob.perform_now(1, {})
    end.not_to raise_error
  end

  it 'keeps a temporary consumer for the retired history queue' do
    expect(Rails.root.join('config/sidekiq.yml').read).to include('- linkedin_personal_history')
  end
end
