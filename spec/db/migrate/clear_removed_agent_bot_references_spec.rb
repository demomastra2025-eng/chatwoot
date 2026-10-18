require 'rails_helper'
require Rails.root.join('db/migrate/20261018120000_clear_removed_agent_bot_references')

# The AgentBot class is gone, so the leftovers are written and read with plain SQL: a polymorphic type string that
# names a missing class would raise a NameError the moment the association is loaded.
# rubocop:disable Rails/SkipsModelValidations
RSpec.describe ClearRemovedAgentBotReferences do
  let(:db) { ActiveRecord::Base.connection }
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:agent) { create(:user, account: account) }

  def run_migration(times: 1)
    ActiveRecord::Migration.suppress_messages { times.times { described_class.new.up } }
  end

  def message_sender(message)
    db.select_rows("SELECT sender_type, sender_id FROM messages WHERE id = #{message.id.to_i}").first
  end

  def notification_actor(notification)
    db.select_rows("SELECT secondary_actor_type, secondary_actor_id FROM notifications WHERE id = #{notification.id.to_i}").first
  end

  def bot_message
    create(:message, account: account, conversation: conversation, message_type: :outgoing).tap do |message|
      Message.where(id: message.id).update_all(sender_type: 'AgentBot', sender_id: 41)
    end
  end

  it 'clears the sender of messages written by an agent bot and keeps every other sender' do
    from_bot = bot_message
    from_user = create(:message, account: account, conversation: conversation, message_type: :outgoing, sender: agent)
    from_assistant = create(:message, account: account, conversation: conversation, message_type: :outgoing,
                                      sender: create(:captain_assistant, account: account))

    run_migration

    expect(message_sender(from_bot)).to eq([nil, nil])
    expect(message_sender(from_user)).to eq(['User', agent.id])
    expect(message_sender(from_assistant).first).to eq('Captain::Assistant')
  end

  it 'clears the actor of status transitions and the user of audits that belong to an agent bot' do
    now = Time.current
    ConversationStatusTransition.insert_all!(
      [
        { account_id: account.id, conversation_id: conversation.id, actor_type: 'AgentBot', actor_id: 41,
          from_status: 'pending', to_status: 'open', source: 'manual', created_at: now, updated_at: now },
        { account_id: account.id, conversation_id: conversation.id, actor_type: 'User', actor_id: agent.id,
          from_status: 'open', to_status: 'resolved', source: 'manual', created_at: now, updated_at: now }
      ]
    )
    Audited::Audit.insert_all!(
      [
        { auditable_type: 'Account', auditable_id: account.id, user_type: 'AgentBot', user_id: 41, action: 'update', created_at: now },
        { auditable_type: 'Account', auditable_id: account.id, user_type: 'User', user_id: agent.id, action: 'update', created_at: now }
      ]
    )

    run_migration

    transitions = db.select_rows("SELECT actor_type, actor_id FROM conversation_status_transitions WHERE conversation_id = #{conversation.id}")
    expect(transitions).to contain_exactly([nil, nil], ['User', agent.id])
    audits = db.select_rows("SELECT user_type, user_id FROM audits WHERE auditable_id = #{account.id} AND auditable_type = 'Account'")
    expect(audits).to include([nil, nil], ['User', agent.id])
    expect(audits.map(&:first)).not_to include('AgentBot')
  end

  it 'clears the secondary actor of notifications that point at an agent bot and keeps the others' do
    from_bot = create(:notification, account: account, user: agent, primary_actor: conversation)
    from_user = create(:notification, account: account, user: agent, primary_actor: conversation, secondary_actor: agent)
    Notification.where(id: from_bot.id).update_all(secondary_actor_type: 'AgentBot', secondary_actor_id: 41)

    run_migration

    expect(notification_actor(from_bot)).to eq([nil, nil])
    expect(notification_actor(from_user)).to eq(['User', agent.id])
    expect { Notification.find(from_bot.id).push_event_data }.not_to raise_error
  end

  it 'deletes tokens, partner links and avatars of agent bots and keeps the others' do
    platform_app = create(:platform_app)
    now = Time.current
    AccessToken.insert_all!([{ owner_type: 'AgentBot', owner_id: 41, token: SecureRandom.hex(16), created_at: now, updated_at: now }])
    PlatformAppPermissible.insert_all!(
      [
        { platform_app_id: platform_app.id, permissible_type: 'AgentBot', permissible_id: 41, created_at: now, updated_at: now },
        { platform_app_id: platform_app.id, permissible_type: 'Account', permissible_id: account.id, created_at: now, updated_at: now }
      ]
    )
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('avatar'), filename: 'avatar.png', content_type: 'image/png')
    db.execute(<<~SQL.squish)
      INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at)
      VALUES ('avatar', 'AgentBot', 41, #{blob.id}, NOW())
    SQL
    kept_token_count = AccessToken.where.not(owner_type: 'AgentBot').count

    run_migration

    expect(AccessToken.where(owner_type: 'AgentBot')).to be_none
    expect(AccessToken.where.not(owner_type: 'AgentBot').count).to eq(kept_token_count)
    expect(PlatformAppPermissible.where(platform_app_id: platform_app.id).pluck(:permissible_type)).to eq(['Account'])
    expect(db.select_value("SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'AgentBot'")).to eq(0)
  end

  it 'clears the agent bot assignee of conversations and keeps the staff assignee' do
    assigned_to_bot = create(:conversation, account: account)
    assigned_to_agent = create(:conversation, account: account, assignee: agent)
    db.execute("UPDATE conversations SET assignee_agent_bot_id = 41 WHERE id = #{assigned_to_bot.id}")

    run_migration

    expect(db.select_value('SELECT COUNT(*) FROM conversations WHERE assignee_agent_bot_id IS NOT NULL')).to eq(0)
    expect(assigned_to_agent.reload.assignee).to eq(agent)
  end

  it 'works through every row when there are more than one batch' do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    messages = Array.new(5) { bot_message }

    run_migration

    expect(messages.map { |message| message_sender(message) }).to all(eq([nil, nil]))
  end

  it 'is safe to run again' do
    from_bot = bot_message
    run_migration

    expect { run_migration(times: 2) }.not_to raise_error
    expect(message_sender(from_bot)).to eq([nil, nil])
  end

  it 'does not change anything in a database without leftovers' do
    from_user = create(:message, account: account, conversation: conversation, message_type: :outgoing, sender: agent)

    expect { run_migration }.not_to(change { message_sender(from_user) })
  end
end
# rubocop:enable Rails/SkipsModelValidations
