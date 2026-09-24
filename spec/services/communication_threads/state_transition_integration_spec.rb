require 'rails_helper'

RSpec.describe 'Communication thread state transition integration' do # rubocop:disable RSpec/DescribeClass
  let(:account) do
    create(:account).tap { |record| record.enable_features!('communication_threads') }
  end
  let(:contact) { create(:contact, account: account) }

  it 'records one post-convergence created fact' do
    owner = create(:user, account: account, name: 'Initial owner')
    team = create(:team, account: account, name: 'Initial team')
    create(:team_member, team: team, user: owner)
    contact = create(:contact, account: account, owner: owner)
    conversation = create(:conversation, account: account, contact: contact, assignee: owner, team: team, status: :pending)

    thread = conversation.reload.communication_thread
    facts = CommunicationThreadStateTransitionFact.where(
      account_id: account.id,
      communication_thread_id_snapshot: thread.id
    )

    expect(facts.count).to eq(1)
    expect(facts.first).to have_attributes(
      event_kind: 'created',
      contact_id_snapshot: contact.id,
      to_assignee_id: owner.id,
      to_assignee_name: 'Initial owner',
      to_team_id: team.id,
      to_team_name: 'initial team',
      to_status: 'pending',
      reliable_since: facts.first.occurred_at
    )
  end

  it 'rolls back conversation creation if its initial Thread fact fails' do
    allow(CommunicationThreadStateTransitionFact).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'fact failure')

    expect { create(:conversation, account: account, contact: contact) }
      .to raise_error(ActiveRecord::StatementInvalid, 'fact failure')
    expect(Conversation.where(account: account, contact: contact)).to be_empty
    expect(CommunicationThread.where(account: account, contact: contact)).to be_empty
  end

  it 'snapshots the final owner when a new Conversation replaces a different Contact owner' do
    previous = create(:user, account: account)
    replacement = create(:user, account: account)
    owned_contact = create(:contact, account: account, owner: previous)

    conversation = create(:conversation, account: account, contact: owned_contact, assignee: replacement)
    thread = conversation.reload.communication_thread
    facts = CommunicationThreadStateTransitionFact.where(communication_thread_id_snapshot: thread.id)

    expect(facts.count).to eq(1)
    expect(facts.sole).to have_attributes(event_kind: 'created', to_assignee_id: replacement.id)
    expect(owned_contact.reload.owner_id).to eq(replacement.id)
  end

  it 'writes one converged fact for a combined Thread assignment and resolve command' do
    conversation = create(:conversation, account: account, contact: contact, status: :open)
    thread = conversation.reload.communication_thread
    owner = create(:user, account: account)
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    CommunicationThreads::UpdateService.new(
      communication_thread: thread, params: { assignee_id: owner.id, status: 'resolved' },
      accessible_links: thread.communication_thread_conversations
    ).perform

    facts = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: thread.id)
    expect(facts.count).to eq(1)
    expect(facts.sole).to have_attributes(event_kind: 'resolved', to_assignee_id: owner.id, to_status: 'resolved')
    expect(contact.reload.owner_id).to eq(owner.id)
  end

  it 'synchronizes unlinked Contact channels during a Thread owner command before backfill' do
    previous = create(:user, account: account)
    replacement = create(:user, account: account)
    previous_team = create(:team, account: account)
    replacement_team = create(:team, account: account)
    create(:team_member, team: previous_team, user: previous)
    create(:team_member, team: replacement_team, user: replacement)
    contact.update!(owner: previous)
    linked = create(:conversation, account: account, contact: contact, assignee: previous, team: previous_team)
    thread = linked.reload.communication_thread
    account.disable_features!('communication_threads')
    unlinked = create(:conversation, account: account, contact: contact, assignee: previous, team: previous_team)
    account.enable_features!('communication_threads')
    expect(unlinked.reload.communication_thread_conversation).to be_nil
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    CommunicationThreads::UpdateService.new(
      communication_thread: thread, params: { assignee_id: replacement.id },
      accessible_links: thread.communication_thread_conversations
    ).perform

    expect([linked.reload.assignee_id, unlinked.reload.assignee_id]).to eq([replacement.id, replacement.id])
    expect([linked.team_id, unlinked.team_id]).to eq([replacement_team.id, replacement_team.id])
    expect(contact.reload.owner_id).to eq(replacement.id)
    expect(CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                 .where(communication_thread_id_snapshot: thread.id).count).to eq(1)
    CommunicationThreads::BackfillJob.new.perform(account_id: account.id, dry_run: false)
    expect(unlinked.reload.communication_thread).to eq(thread)
    expect(unlinked).to have_attributes(assignee_id: replacement.id, team_id: replacement_team.id)
  end

  it 'repairs stale unlinked channels even when the Thread command keeps the current Contact owner' do
    previous = create(:user, account: account)
    replacement = create(:user, account: account)
    previous_team = create(:team, account: account)
    replacement_team = create(:team, account: account)
    create(:team_member, team: previous_team, user: previous)
    create(:team_member, team: replacement_team, user: replacement)
    contact.update!(owner: previous)
    linked = create(:conversation, account: account, contact: contact, assignee: previous, team: previous_team)
    thread = linked.reload.communication_thread
    account.disable_features!('communication_threads')
    unlinked = create(:conversation, account: account, contact: contact, assignee: previous, team: previous_team)
    account.enable_features!('communication_threads')
    contact.update_column(:owner_id, replacement.id) # rubocop:disable Rails/SkipsModelValidations
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    CommunicationThreads::UpdateService.new(
      communication_thread: thread, params: { assignee_id: replacement.id },
      accessible_links: thread.communication_thread_conversations
    ).perform

    expect(contact.reload.owner_id).to eq(replacement.id)
    expect([linked.reload.assignee_id, unlinked.reload.assignee_id]).to eq([replacement.id, replacement.id])
    expect([linked.team_id, unlinked.team_id]).to eq([replacement_team.id, replacement_team.id])
    expect(CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                 .where(communication_thread_id_snapshot: thread.id).count).to eq(1)
  end

  it 'writes one owner fact after synchronizing two channels for one Contact owner change' do
    first = create(:conversation, account: account, contact: contact)
    second = create(:conversation, account: account, contact: contact)
    thread = first.reload.communication_thread
    owner = create(:user, account: account)
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    contact.update!(owner: owner)

    facts = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: thread.id)
    expect([first.reload.assignee_id, second.reload.assignee_id]).to eq([owner.id, owner.id])
    expect(facts.pluck(:to_assignee_id)).to eq([owner.id])
  end

  it 'preserves an owner transition on deletion of a member with a linkless Thread' do
    owner = create(:user, account: account)
    unlinked = create(:communication_thread, account: account, assignee: owner)
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    account.account_users.find_by!(user_id: owner.id).destroy!

    fact = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                 .where(communication_thread_id_snapshot: unlinked.id).sole
    expect(fact).to have_attributes(from_assignee_id: owner.id, to_assignee_id: nil,
                                    source_record_type: 'AccountUser')
    expect(unlinked.reload.assignee_id).to be_nil
  end

  it 'unassigns stale routing before raw membership deletion by an old process' do
    owner = create(:user, account: account)
    owned_contact = create(:contact, account: account, owner: owner)
    conversation = create(:conversation, account: account, contact: owned_contact, assignee: owner)
    thread = conversation.reload.communication_thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    AccountUser.where(account_id: account.id, user_id: owner.id).delete_all

    fact = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                 .where(communication_thread_id_snapshot: thread.id).sole
    expect(fact).to have_attributes(from_assignee_id: owner.id, to_assignee_id: nil,
                                    source: 'database_projection_fallback')
    expect(thread.reload.assignee_id).to be_nil
    expect(conversation.reload.assignee_id).to be_nil
    expect(owned_contact.reload.owner_id).to be_nil
  end

  it 'unassigns a Thread while its owner is still a workspace member' do
    owner = create(:user, account: account)
    owned_contact = create(:contact, account: account, owner: owner)
    conversation = create(:conversation, account: account, contact: owned_contact, assignee: owner)
    thread = conversation.reload.communication_thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    account.account_users.find_by!(user_id: owner.id).destroy!

    facts = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: thread.id)
    expect(facts.map(&:event_kind)).to eq(['routing_changed'])
    expect(facts.sole).to have_attributes(
      from_assignee_id: owner.id, to_assignee_id: nil, source: 'workspace_membership_removed'
    )
    expect(thread.reload.assignee_id).to be_nil
    expect(conversation.reload.assignee_id).to be_nil
    expect(owned_contact.reload.owner_id).to be_nil
  end

  it 'records one fact for one multi-conversation aggregate command' do
    contact = create(:contact, account: account)
    first = create(:conversation, account: account, contact: contact, status: :open)
    second = create(:conversation, account: account, contact: contact, status: :open)
    thread = first.reload.communication_thread
    last_fact_id = CommunicationThreadStateTransitionFact.where(account: account).maximum(:id).to_i

    CommunicationThreads::UpdateService.new(
      communication_thread: thread,
      params: ActionController::Parameters.new(status: 'resolved').permit!,
      accessible_links: thread.communication_thread_conversations,
      source: 'aggregate_spec'
    ).perform

    new_facts = CommunicationThreadStateTransitionFact.where(account: account).where('id > ?', last_fact_id)
    expect(first.reload).to be_resolved
    expect(second.reload).to be_resolved
    expect(new_facts.count).to eq(1)
    expect(new_facts.first).to have_attributes(event_kind: 'resolved', source: 'aggregate_spec')
  end

  it 'uses the same fact event for status activities on every linked channel' do
    first = create(:conversation, account: account, contact: contact, status: :open)
    second = create(:conversation, account: account, contact: contact, status: :open)
    thread = first.reload.communication_thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)
    Current.user = create(:user, account: account)

    perform_enqueued_jobs(only: Conversations::ActivityMessageJob) do
      CommunicationThreads::UpdateService.new(
        communication_thread: thread, params: { status: 'resolved' },
        accessible_links: thread.communication_thread_conversations
      ).perform
    end

    fact = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                 .where(communication_thread_id_snapshot: thread.id).sole
    activities = Message.where(conversation_id: [first.id, second.id], message_type: :activity)
                        .where("additional_attributes ? 'communication_thread_event_id'").to_a
    expect(activities.size).to eq(2)
    expect(activities.map(&:content).uniq.size).to eq(1)
    expect(activities.map { |message| message.additional_attributes['communication_thread_event_id'] })
      .to eq([fact.source_event_id] * 2)
  ensure
    Current.user = nil
  end

  it 'records stable contact actor identity for a contact-initiated status transition' do
    conversation = create(:conversation, account: account, contact: contact, status: :open)
    thread = conversation.reload.communication_thread

    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: 'resolved' },
      actor: contact,
      source: 'widget'
    ).perform

    fact = thread.communication_thread_state_transition_facts.order(:id).last
    expect(fact).to have_attributes(actor_kind: 'contact', actor_id: contact.id, actor_name: contact.name)
  end

  it 'records MacroCRM string executor as a named unknown actor without blocking assignment' do
    conversation = create(:conversation, account: account, contact: contact)
    thread = conversation.reload.communication_thread
    owner = create(:user, account: account)
    executor = 'Integrations::Macrocrm::ManagerChangedProcessorService'
    previous_executor = Current.executed_by

    begin
      Current.executed_by = executor
      Conversations::AssignmentService.new(conversation: conversation, assignee_id: owner.id).perform
    ensure
      Current.executed_by = previous_executor
    end

    expect(thread.reload.assignee_id).to eq(owner.id)
    expect(thread.communication_thread_state_transition_facts.order(:id).last)
      .to have_attributes(actor_kind: 'unknown', actor_id: nil, actor_name: executor)
  end

  it 'retains Captain assistant identity as an account-scoped actor' do
    conversation = create(:conversation, account: account, contact: contact, status: :open)
    assistant = create(:captain_assistant, account: account, name: 'AI assistant')
    thread = conversation.reload.communication_thread

    Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'resolved' },
                                               actor: assistant).perform

    expect(thread.communication_thread_state_transition_facts.order(:id).last)
      .to have_attributes(actor_kind: 'captain', actor_id: assistant.id, actor_name: assistant.name)
  end

  it 'writes one post-convergence fact for mixed aggregate statuses' do
    pending = create(:conversation, account: account, contact: contact, status: :pending, last_activity_at: 1.hour.ago)
    opened = create(:conversation, account: account, contact: contact, status: :open, last_activity_at: 2.hours.ago)
    thread = pending.reload.communication_thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    Conversations::StatusTransitionService.new(
      conversation: pending,
      params: { status: 'resolved' },
      source: 'mixed_aggregate_spec'
    ).perform

    facts = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: thread.id)
    expect([pending.reload.status, opened.reload.status]).to eq(%w[resolved resolved])
    expect(facts.map(&:event_kind)).to eq(['resolved'])
  end

  it 'uses a fresh operation identity for repeated transitions on one conversation instance' do
    conversation = create(:conversation, account: account, contact: contact, status: :open)
    thread = conversation.reload.communication_thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'resolved' }).perform
    Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'open' }).perform

    facts = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: thread.id)
                                                  .order(:id)
    expect(facts.map(&:event_kind)).to eq(%w[resolved reopened])
    expect(facts.map(&:source_event_id).uniq.size).to eq(2)
  end

  it 'clears a status service event before a direct update on the same instance' do
    conversation = create(:conversation, account: account, contact: contact, status: :open)
    thread = conversation.reload.communication_thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'resolved' }).perform
    conversation.update!(status: :pending, priority: :urgent)

    facts = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: thread.id)
                                                  .order(:id)
    expect(facts.pluck(:to_status)).to eq(%w[resolved pending])
    expect(facts.map(&:source_event_id).uniq.size).to eq(2)
    expect(thread.reload).to have_attributes(status: 'pending', priority: 'urgent')
  end

  it 'does not leak a no-op status service actor into the next direct mutation' do
    conversation = create(:conversation, account: account, contact: contact, status: :open)
    thread = conversation.reload.communication_thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'open' },
                                               actor: contact, source: 'widget').perform
    conversation.update!(status: :resolved)

    fact = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                 .where(communication_thread_id_snapshot: thread.id).sole
    expect(fact).to have_attributes(source: 'conversation_callback', actor_kind: 'system', to_status: 'resolved')
  end

  it 'rolls back a direct conversation transition when the fact cannot be inserted' do
    owner = create(:user, account: account)
    conversation = create(:conversation, account: account, contact: contact)

    allow(CommunicationThreadStateTransitionFact).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'fact failure')

    expect { conversation.update!(assignee: owner) }.to raise_error(ActiveRecord::StatementInvalid, 'fact failure')
    expect(conversation.reload.assignee_id).to be_nil
  end

  it 'rolls back Contact owner changes when a Thread fact fails' do
    conversation = create(:conversation, account: account, contact: contact)
    owner = create(:user, account: account)
    thread = conversation.reload.communication_thread
    allow(CommunicationThreadStateTransitionFact).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'fact failure')

    expect { contact.update!(owner: owner) }.to raise_error(ActiveRecord::StatementInvalid, 'fact failure')
    expect(contact.reload.owner_id).to be_nil
    expect(conversation.reload.assignee_id).to be_nil
    expect(thread.reload.assignee_id).to be_nil
  end

  it 'uses the database fallback for state changes made by rolling old processes' do
    thread = create(:communication_thread, account: account, contact: contact, status: :open)
    baseline_id = thread.communication_thread_state_transition_facts.maximum(:id)

    thread.update_columns(status: CommunicationThread.statuses.fetch('resolved'), updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations

    fact = thread.communication_thread_state_transition_facts.where('id > ?', baseline_id).sole
    expect(fact).to have_attributes(event_kind: 'resolved', from_status: 'open', to_status: 'resolved',
                                    source: 'database_projection_fallback', actor_kind: 'system')
  end

  it 'records direct callback routing and contact-owner synchronization once per effective state' do
    conversation = create(:conversation, account: account)
    thread = conversation.reload.communication_thread
    owner = create(:user, account: account, name: 'Direct owner')
    team = create(:team, account: account, name: 'Direct team')
    create(:team_member, team: team, user: owner)
    baseline = CommunicationThreadStateTransitionFact.where(account: account).count

    conversation.update!(assignee: owner, team: team)
    direct_fact = CommunicationThreadStateTransitionFact.where(account: account).order(:id).last
    expect(direct_fact).to have_attributes(event_kind: 'routing_changed', to_assignee_id: owner.id, to_team_id: team.id)

    replacement = create(:user, account: account, name: 'Replacement owner')
    create(:team_member, team: team, user: replacement)
    conversation.contact.update!(owner: replacement)

    facts = CommunicationThreadStateTransitionFact.where(account: account).order(:id).to_a.drop(baseline)
    expect(facts.map(&:to_assignee_id)).to eq([owner.id, replacement.id])
    expect(thread.reload.assignee_id).to eq(replacement.id)
    expect(facts.last.source).to eq('contact_owner_sync')
  end

  it 'converges a direct Conversation owner and team transfer into one fact' do
    original_team = create(:team, account: account)
    replacement_team = create(:team, account: account)
    original_owner = create(:user, account: account)
    replacement = create(:user, account: account)
    create(:team_member, team: original_team, user: original_owner)
    create(:team_member, team: replacement_team, user: replacement)
    conversation = create(:conversation, account: account, contact: contact, assignee: original_owner, team: original_team)
    thread = conversation.reload.communication_thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    conversation.update!(assignee: replacement, team: replacement_team)

    facts = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: thread.id)
    expect(facts.count).to eq(1)
    expect(facts.sole).to have_attributes(to_assignee_id: replacement.id, to_team_id: replacement_team.id)
    expect(thread.reload).to have_attributes(assignee_id: replacement.id, team_id: replacement_team.id)
  end

  it 'records only the final state of a direct combined assignee and status update' do
    first = create(:conversation, account: account, contact: contact, status: :resolved)
    second = create(:conversation, account: account, contact: contact, status: :resolved)
    thread = first.reload.communication_thread
    owner = create(:user, account: account)
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    second.update!(assignee: owner, status: :open)

    facts = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: thread.id)
    expect(facts.count).to eq(1)
    expect(facts.sole).to have_attributes(
      event_kind: 'reopened', from_status: 'resolved', to_status: 'open',
      to_assignee_id: owner.id, source: 'conversation_callback'
    )
    expect(first.reload.assignee_id).to eq(owner.id)
    expect(contact.reload.owner_id).to eq(owner.id)
    expect(thread.reload).to have_attributes(status: 'open', assignee_id: owner.id)
  end

  it 'records one reopened fact when an incoming message reopens a resolved conversation' do
    conversation = create(:conversation, account: account, status: :resolved)
    thread = CommunicationThread.find_by!(account: account, contact: conversation.contact)
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id).to_i

    create(:message, conversation: conversation, message_type: :incoming)

    facts = CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)
                                                  .where(communication_thread_id_snapshot: thread.id)
    expect(facts.map(&:event_kind)).to eq(['reopened'])
    expect(thread.reload).to be_open
  end

  it 'records team nullification before deleting the live dimension' do
    team = create(:team, account: account, name: 'Deleted team')
    conversation = create(:conversation, account: account, team: team)
    thread = conversation.reload.communication_thread

    expect { team.destroy! }.to change(CommunicationThreadStateTransitionFact, :count).by(1)

    expect(thread.reload.team_id).to be_nil
    expect(CommunicationThreadStateTransitionFact.order(:id).last).to have_attributes(
      source: 'team_deleted',
      from_team_id: team.id,
      from_team_name: 'deleted team',
      to_team_id: nil
    )
  end

  it 'refreshes a surviving thread after deleting its current routing conversation' do
    contact = create(:contact, account: account)
    old_owner = create(:user, account: account)
    surviving_owner = create(:user, account: account)
    surviving = create(:conversation, account: account, contact: contact, assignee: surviving_owner, last_activity_at: 2.hours.ago)
    deleted = create(:conversation, account: account, contact: contact, assignee: old_owner, last_activity_at: 1.hour.ago)
    thread = deleted.reload.communication_thread
    expect(thread.reload.assignee_id).to eq(old_owner.id)
    surviving.update_column(:assignee_id, surviving_owner.id) # rubocop:disable Rails/SkipsModelValidations
    contact.update_column(:owner_id, nil) # rubocop:disable Rails/SkipsModelValidations

    described_class_name = CommunicationThreadStateTransitionFact.name
    fact_count = described_class_name.constantize.count
    DeleteObjectJob.perform_now(deleted, old_owner)

    expect(thread.reload.assignee_id).to eq(surviving_owner.id)
    expect(described_class_name.constantize.count).to eq(fact_count + 1)
    expect(thread.communication_thread_conversations.where(primary: true).count).to eq(1)
    expect(CommunicationThreadStateTransitionFact.order(:id).last).to have_attributes(
      source: 'record_deleted',
      from_assignee_id: old_owner.id,
      to_assignee_id: surviving_owner.id
    )
  end

  it 'rolls back the Conversation deletion when the surviving Thread fact fails' do
    first = create(:conversation, account: account, contact: contact, status: :open, last_activity_at: 2.hours.ago)
    deleted = create(:conversation, account: account, contact: contact, status: :pending, last_activity_at: 1.hour.ago)
    thread = deleted.reload.communication_thread
    expect(thread.reload).to be_pending
    allow(CommunicationThreadStateTransitionFact).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'fact failure')

    expect { DeleteObjectJob.perform_now(deleted) }.to raise_error(ActiveRecord::StatementInvalid, 'fact failure')
    expect(deleted.reload).to be_persisted
    expect(first.reload).to be_persisted
    expect(thread.reload).to be_pending
    expect(thread.communication_thread_conversations.count).to eq(2)
  end
end
