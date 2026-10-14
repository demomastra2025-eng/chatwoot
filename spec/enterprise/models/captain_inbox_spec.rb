require 'rails_helper'

RSpec.describe CaptainInbox do
  include ActiveJob::TestHelper
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  it 'leaves a newly initialized channel disabled by default' do
    assignment = described_class.new(inbox: inbox, captain_assistant: assistant)

    expect(assignment.ai_enabled).to be false
  end

  it 'rejects new inactive and internal entry agents' do
    assistant.update!(active: false)
    expect(build(:captain_inbox, inbox: inbox, captain_assistant: assistant)).not_to be_valid
    assistant.update!(active: true, usage_mode: 'internal_assistant')
    expect(build(:captain_inbox, inbox: inbox, captain_assistant: assistant)).not_to be_valid
  end

  it 'rejects entry assignments from another workspace' do
    expect(build(:captain_inbox, inbox: inbox, captain_assistant: create(:captain_assistant))).not_to be_valid
  end

  it 'applies the workspace emergency switch and reply time to text channels' do
    inbox
    account.update!(captain_default_assistant_id: assistant.id)
    link = create(:captain_inbox, inbox: inbox, captain_assistant: assistant, ai_enabled: true)
    expect(link.auto_reply_allowed_now?).to be(true)

    account.update!(captain_agent_settings: { 'routing' => { 'ai_enabled' => false, 'auto_reply_mode' => 'always' } })
    link.inbox.account.reload
    expect(link.auto_reply_allowed_now?).to be(false)
    expect(described_class.enabled_for_runtime.where(id: link.id)).not_to exist

    schedule = AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup
    account.update!(workspace_working_hours: schedule,
                    captain_agent_settings: { 'routing' => { 'ai_enabled' => true, 'auto_reply_mode' => 'working_hours' } })
    link.inbox.account.reload
    travel_to(ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 9, 7, 10, 0)) do
      expect(link.auto_reply_allowed_now?).to be(true)
    end
    travel_to(ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 9, 6, 10, 0)) do
      expect(link.auto_reply_allowed_now?).to be(false)
    end
  end

  it 'uses workspace hours even when the channel has different hours' do
    link = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    inbox.update!(working_hours_enabled: true)
    inbox.working_hours.find_by!(day_of_week: Time.current.in_time_zone(inbox.timezone).wday)
         .update!(closed_all_day: true, open_all_day: false)
    open_schedule = (0..6).map { |day| { 'day_of_week' => day, 'open_all_day' => true, 'closed_all_day' => false } }
    account.update!(workspace_working_hours: open_schedule,
                    captain_agent_settings: { 'routing' => { 'auto_reply_mode' => 'working_hours' } })
    link.inbox.account.reload

    expect(link.auto_reply_allowed_now?).to be(true)

    closed_schedule = open_schedule.map { |day| day.merge('open_all_day' => false, 'closed_all_day' => true) }
    account.update!(workspace_working_hours: closed_schedule)
    link.inbox.account.reload

    expect(link.auto_reply_allowed_now?).to be(false)
  end

  it 'allows an active external agent on any text inbox regardless of legacy channel scope' do
    assistant.update!(channel_scope: 'selected')
    assignment = build(:captain_inbox, inbox: inbox, captain_assistant: assistant)

    expect(assignment).to be_valid
  end

  it 'retains the configured entry when the agent is temporarily deactivated' do
    assignment = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    assignment.update!(ai_enabled: false)
    account.update!(captain_default_assistant_id: nil)
    assistant.update!(active: false)

    expect(assignment.reload).to be_valid
    expect(assignment.captain_assistant_id).to eq(assistant.id)
  end

  it 'acquires the shared assistant assignment lock on save and destroy' do
    captain_inbox = build(:captain_inbox, inbox: inbox, captain_assistant: assistant)

    expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).with(inbox.id).exactly(3).times.and_call_original
    captain_inbox.save!
    captain_inbox.update!(auto_reply_mode: 'working_hours')
    captain_inbox.destroy!
  end

  it 'uses the shared lock when an assistant asynchronously destroys its assignments' do
    captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    captain_inbox.update!(ai_enabled: false)
    account.update!(captain_default_assistant_id: nil)

    expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).with(inbox.id).twice.and_call_original
    perform_enqueued_jobs { assistant.destroy! }

    expect(described_class.where(id: captain_inbox.id)).not_to exist
  end

  it 'rolls back assignment creation when routing policy sync fails' do
    captain_inbox = build(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    allow(captain_inbox).to receive(:sync_voice_routing_policy!).and_raise('sync failed')

    expect do
      described_class.transaction(requires_new: true) { captain_inbox.save! }
    end.to raise_error(RuntimeError, 'sync failed')

    expect(described_class.where(inbox_id: inbox.id)).not_to exist
  end

  it 'rolls back assignment deletion when routing policy cleanup fails' do
    captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    allow(captain_inbox).to receive(:clear_voice_routing_policy).and_raise('cleanup failed')

    expect do
      described_class.transaction(requires_new: true) { captain_inbox.destroy! }
    end.to raise_error(RuntimeError, 'cleanup failed')

    expect(described_class.where(id: captain_inbox.id)).to exist
  end
end
