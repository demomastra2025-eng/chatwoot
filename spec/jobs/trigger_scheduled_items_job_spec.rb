require 'rails_helper'

RSpec.describe TriggerScheduledItemsJob do
  subject(:job) { described_class.perform_later }

  let(:account) { create(:account) }

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .on_queue('scheduled_jobs')
  end

  it 'triggers Conversations::ReopenSnoozedConversationsJob' do
    expect(Conversations::ReopenSnoozedConversationsJob).to receive(:perform_later).once
    described_class.perform_now
  end

  it 'triggers Notification::ReopenSnoozedNotificationsJob' do
    expect(Notification::ReopenSnoozedNotificationsJob).to receive(:perform_later).once
    described_class.perform_now
  end

  it 'triggers Account::ConversationsResolutionSchedulerJob' do
    expect(Account::ConversationsResolutionSchedulerJob).to receive(:perform_later).once
    described_class.perform_now
  end

  it 'triggers Channels::Whatsapp::TemplatesSyncSchedulerJob' do
    expect(Channels::Whatsapp::TemplatesSyncSchedulerJob).to receive(:perform_later).once
    described_class.perform_now
  end

  it 'triggers Reminders::ProcessPendingRemindersJob' do
    expect(Reminders::ProcessPendingRemindersJob).to receive(:perform_later).once
    described_class.perform_now
  end

  it 'only enqueues the new Automation replay class after fleet activation' do
    allow(AutomationRules::ReplayEventsJob).to receive(:perform_later)

    with_modified_env(AUTOMATION_DURABLE_EVENT_PUBLICATION_ENABLED: 'false') { described_class.perform_now }
    expect(AutomationRules::ReplayEventsJob).not_to have_received(:perform_later)

    with_modified_env(AUTOMATION_DURABLE_EVENT_PUBLICATION_ENABLED: 'true') { described_class.perform_now }
    expect(AutomationRules::ReplayEventsJob).to have_received(:perform_later).once
  end

  context 'when unexecuted Scheduled campaign jobs' do
    let!(:twilio_sms) { create(:channel_twilio_sms, account: account) }
    let!(:twilio_inbox) { create(:inbox, channel: twilio_sms, account: account) }

    it 'triggers Campaigns::TriggerOneoffCampaignJob once while the launch lease is active' do
      campaign = create(:campaign, inbox: twilio_inbox, account: account)
      create(:campaign, inbox: twilio_inbox, account: account, scheduled_at: 10.days.after)
      expect(Campaigns::TriggerOneoffCampaignJob).to receive(:perform_later).with(campaign).once
      described_class.perform_now
      described_class.perform_now
    end
  end
end
