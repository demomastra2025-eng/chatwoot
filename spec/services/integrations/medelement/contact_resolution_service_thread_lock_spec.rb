require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::ContactResolutionService do
  self.use_transactional_tests = false

  def wait_until_blocked!(blocked_pid, blocker_pid)
    Timeout.timeout(10) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{Integer(blocked_pid)})")
        break if blockers.include?(blocker_pid.to_s)

        sleep 0.01
      end
    end
  end

  def cleanup_account(account)
    return unless account&.persisted?

    AutomationEvent.where(account_id: account.id).delete_all
    ConversationStatusTransition.where(account_id: account.id).delete_all
    CommunicationThreadConversation.where(account_id: account.id).delete_all
    CommunicationThread.where(account_id: account.id).destroy_all
    account.destroy!
  end

  # rubocop:disable RSpec/ExampleLength
  it 'claims both thread advisors before locking the MedElement conflict and either Contact row' do
    account = create(:account)
    account.enable_features!('communication_threads', 'scheduling')
    admin = create(:user, account: account, role: :administrator)
    agent = create(:user, account: account)
    hook = create(:integrations_hook, :medelement, account: account)
    run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'manual', status: 'partial')
    base = create(:contact, account: account, custom_attributes: { 'medelement_patient_code' => 'patient-1' })
    mergee = create(:contact, account: account)
    inbox = create(:channel_widget, account: account).inbox
    base_conversation = create(:conversation, account: account, inbox: inbox, contact: base)
    mergee_conversation = create(:conversation, account: account, inbox: inbox, contact: mergee)
    thread_id = base_conversation.reload.communication_thread.id
    conflict = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'contacts', entity_type: 'contact', conflict_type: 'phone_owned_by_another_contact', entity_key: 'patient-1',
      details: { contact_id: base.id, conflicting_contact_id: mergee.id, reason: 'Phone ownership conflict' }
    )
    service = described_class.new(conflict: conflict, user: admin)
    held = Queue.new
    release = Queue.new
    route_started = Queue.new
    allow(service).to receive(:locked_contacts!).and_wrap_original do |original, *args|
      original.call(*args).tap do
        held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        release.pop
      end
    end

    merger = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service.merge_contacts!(base_contact_id: base.id, mergee_contact_id: mergee.id)
      end
    end
    merger_pid = Timeout.timeout(10) { held.pop }
    router = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        route_started << connection.select_value('SELECT pg_backend_pid()').to_i
        thread = CommunicationThread.find(thread_id)
        CommunicationThreads::UpdateService.new(
          communication_thread: thread, params: { assignee_id: agent.id },
          accessible_links: thread.communication_thread_conversations
        ).perform
      end
    end
    router_pid = Timeout.timeout(10) { route_started.pop }
    wait_until_blocked!(router_pid, merger_pid)
    wait_event = ActiveRecord::Base.connection.select_value(
      "SELECT wait_event FROM pg_stat_activity WHERE pid = #{router_pid}"
    )
    expect(wait_event).to eq('advisory')
    release << true
    Timeout.timeout(15) { merger.value }
    Timeout.timeout(15) { router.value }

    expect(conflict.reload).to be_resolved
    expect(Contact.exists?(mergee.id)).to be(false)
    expect(mergee_conversation.reload).to have_attributes(contact_id: base.id)
    expect(base.reload.owner_id).to eq(agent.id)
    expect(CommunicationThread.find(thread_id).assignee_id).to eq(agent.id)
  ensure
    release << true if merger&.alive?
    [merger, router].compact.each { |writer| writer.kill if writer.alive? }
    [merger, router].compact.each(&:join)
    cleanup_account(account)
  end
  # rubocop:enable RSpec/ExampleLength
end
