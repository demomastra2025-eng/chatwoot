require 'rails_helper'

RSpec.describe 'retired domain job compatibility' do
  it 'discards an AgentBot webhook job enqueued by an older release' do
    expect do
      AgentBots::WebhookJob.perform_now('https://example.test/webhook', {}, :agent_bot_webhook)
    end.not_to raise_error
  end

  it 'discards LinkedIn Personal webhook jobs enqueued by an older release' do
    expect do
      Channels::LinkedinPersonal::ProcessWebhookEventJob.perform_now(1, {})
      Channels::LinkedinPersonal::ProcessHistoryWebhookEventJob.perform_now(1, {})
    end.not_to raise_error
  end

  it 'keeps a temporary consumer for the retired LinkedIn Personal history queue' do
    expect(Rails.root.join('config/sidekiq.yml').read).to include('- linkedin_personal_history')
  end

  it 'discards a SAML provider update job enqueued by an older release' do
    expect do
      Saml::UpdateAccountUsersProviderJob.perform_now(1, 'saml')
    end.not_to raise_error
  end
end
