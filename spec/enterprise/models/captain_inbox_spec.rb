require 'rails_helper'

RSpec.describe CaptainInbox do
  include ActiveJob::TestHelper
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:voice_inbox) { create_voice_inbox(account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  it 'leaves a newly initialized channel disabled by default' do
    assignment = described_class.new(inbox: inbox)

    expect(assignment.ai_enabled).to be false
  end

  describe 'a text channel row' do
    it 'holds the channel settings only: it is valid with no agent' do
      row = build(:captain_inbox, inbox: inbox)

      expect(row).to be_valid
      expect(row.captain_assistant_id).to be_nil
    end

    it 'rejects an agent: the router picks the agent, a text channel does not name one' do
      row = build(:captain_inbox, inbox: inbox, captain_assistant: assistant)

      expect(row).not_to be_valid
      expect(row.errors[:captain_assistant]).to be_present
    end
  end

  describe 'a WhatsApp number whose calls the AI answers' do
    let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }

    def whatsapp_inbox(ai_voice:)
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false,
                                provider_config: { 'ai_voice_enabled' => ai_voice }).inbox
    end

    it 'may name the agent that answers its calls, like a phone number: a call has no router' do
      row = build(:captain_inbox, inbox: whatsapp_inbox(ai_voice: true), captain_assistant: assistant)

      expect(row).to be_valid
      expect(row.answers_calls_with_ai?).to be(true)
    end

    it 'is valid with no agent: its text settings do not need one' do
      expect(build(:captain_inbox, inbox: whatsapp_inbox(ai_voice: true))).to be_valid
    end

    it 'rejects an agent while its AI voice is off: then it is a text channel' do
      row = build(:captain_inbox, inbox: whatsapp_inbox(ai_voice: false), captain_assistant: assistant)

      expect(row.answers_calls_with_ai?).to be(false)
      expect(row).not_to be_valid
      expect(row.errors[:captain_assistant]).to be_present
    end

    it 'rejects an agent from another workspace' do
      row = build(:captain_inbox, inbox: whatsapp_inbox(ai_voice: true), captain_assistant: create(:captain_assistant))

      expect(row).not_to be_valid
    end
  end

  describe 'a voice channel row' do
    it 'needs an agent: a call has no router' do
      expect(build(:captain_inbox, inbox: voice_inbox, captain_assistant: nil)).not_to be_valid
      expect(build(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)).to be_valid
    end

    it 'rejects new inactive and internal agents' do
      assistant.update!(active: false)
      expect(build(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)).not_to be_valid
      assistant.update!(active: true, usage_mode: 'internal_assistant')
      expect(build(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)).not_to be_valid
    end

    it 'rejects an agent from another workspace' do
      expect(build(:captain_inbox, inbox: voice_inbox, captain_assistant: create(:captain_assistant))).not_to be_valid
    end

    it 'retains the voice agent when it is temporarily deactivated' do
      assignment = create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
      assistant.update!(active: false)

      expect(assignment.reload).to be_valid
      expect(assignment.captain_assistant_id).to eq(assistant.id)
    end
  end

  describe '.enabled_for_runtime' do
    it 'includes a text channel that is switched on in a workspace with an enabled agent, with no agent on the row' do
      assistant
      row = create(:captain_inbox, inbox: inbox, ai_enabled: true)

      expect(described_class.enabled_for_runtime.where(id: row.id)).to exist
    end

    it 'leaves out a text channel that is switched off' do
      assistant
      row = create(:captain_inbox, inbox: inbox, ai_enabled: false)

      expect(described_class.enabled_for_runtime.where(id: row.id)).not_to exist
    end

    it 'leaves out a text channel when every agent of the workspace is off, and brings it back with the first agent turned on' do
      assistant.update!(active: false)
      row = create(:captain_inbox, inbox: inbox, ai_enabled: true)

      expect(described_class.enabled_for_runtime.where(id: row.id)).not_to exist

      assistant.update!(active: true)
      expect(described_class.enabled_for_runtime.where(id: row.id)).to exist
    end

    it 'does not count an internal assistant as an agent' do
      create(:captain_assistant, account: account, usage_mode: 'internal_assistant')
      row = create(:captain_inbox, inbox: inbox, ai_enabled: true)

      expect(described_class.enabled_for_runtime.where(id: row.id)).not_to exist
    end

    it 'keeps a text channel open while any agent is on, whichever agent is turned off' do
      first = create(:captain_assistant, account: account)
      second = create(:captain_assistant, account: account)
      row = create(:captain_inbox, inbox: inbox, ai_enabled: true)

      first.update!(active: false)
      expect(described_class.enabled_for_runtime.where(id: row.id)).to exist
      second.update!(active: false)
      expect(described_class.enabled_for_runtime.where(id: row.id)).not_to exist
    end

    it 'includes a voice channel while its own agent is on, whatever the other agents do' do
      other = create(:captain_assistant, account: account)
      row = create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)

      expect(described_class.enabled_for_runtime.where(id: row.id)).to exist
      other.update!(active: false)
      expect(described_class.enabled_for_runtime.where(id: row.id)).to exist
      assistant.update!(active: false)
      expect(described_class.enabled_for_runtime.where(id: row.id)).not_to exist
    end
  end

  it 'applies the workspace emergency switch and reply time to text channels' do
    assistant
    link = create(:captain_inbox, inbox: inbox, ai_enabled: true)
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
    link = create(:captain_inbox, inbox: inbox)
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

  it 'acquires the shared assistant assignment lock on save and destroy' do
    captain_inbox = build(:captain_inbox, inbox: inbox)

    expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).with(inbox.id).exactly(3).times.and_call_original
    captain_inbox.save!
    captain_inbox.update!(auto_reply_mode: 'working_hours')
    captain_inbox.destroy!
  end

  it 'uses the shared lock when a voice agent destroys its assignments' do
    captain_inbox = create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
    captain_inbox.update!(ai_enabled: false)

    expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).with(voice_inbox.id).at_least(:twice).and_call_original
    assistant.destroy!

    expect(described_class.where(id: captain_inbox.id)).not_to exist
  end

  it 'rolls back assignment creation when routing policy sync fails' do
    captain_inbox = build(:captain_inbox, inbox: inbox)
    allow(captain_inbox).to receive(:sync_voice_routing_policy!).and_raise('sync failed')

    expect do
      described_class.transaction(requires_new: true) { captain_inbox.save! }
    end.to raise_error(RuntimeError, 'sync failed')

    expect(described_class.where(inbox_id: inbox.id)).not_to exist
  end

  it 'rolls back assignment deletion when routing policy cleanup fails' do
    captain_inbox = create(:captain_inbox, inbox: inbox)
    allow(captain_inbox).to receive(:clear_voice_routing_policy).and_raise('cleanup failed')

    expect do
      described_class.transaction(requires_new: true) { captain_inbox.destroy! }
    end.to raise_error(RuntimeError, 'cleanup failed')

    expect(described_class.where(id: captain_inbox.id)).to exist
  end
end
