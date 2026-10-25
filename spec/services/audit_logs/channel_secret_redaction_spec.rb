require 'rails_helper'
require 'rake'

RSpec.describe AuditLogs::ChannelSecretRedaction do
  let(:channel) { create(:channel_telegram_personal) }
  let(:inbox) { channel.inbox }
  let(:session) { '1BVtsOK8Bu-stored-session' }
  let(:object_changes) do
    {
      'string_session' => [nil, session],
      'runtime_state' => [{}, { 'qr_login_url' => 'tg://login?token=stored-login-token' }],
      'phone_number' => ['+77010000001', '+77010000002']
    }
  end
  let(:string_changes) { { 'api_hash' => %w[stored-old-hash stored-new-hash] } }
  let!(:session_row_id) { insert_audit(inbox, object_changes) }
  let!(:string_row_id) { insert_audit(inbox, string_changes, as_string: true) }
  let!(:clean_row_id) { insert_audit(inbox, { 'name' => %w[old new] }) }

  def connection
    Audited::Audit.connection
  end

  # Written straight into the table, the way entries got there before the filter: as a JSON object or as a JSON string
  def insert_audit(target_inbox, changes, as_string: false)
    json = connection.quote(changes.to_json)
    value = as_string ? "to_jsonb(#{json}::text)" : "#{json}::jsonb"
    connection.select_value(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action, audited_changes, version, created_at)
      VALUES ('Inbox', #{target_inbox.id.to_i}, 'Account', #{target_inbox.account_id.to_i}, 'update', #{value}, 1, NOW())
      RETURNING id
    SQL
  end

  def stored(id)
    connection.select_one("SELECT jsonb_typeof(audited_changes) AS storage, audited_changes::text AS raw FROM audits WHERE id = #{id.to_i}")
  end

  def run_task(**env)
    Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:audits:redact_channel_secrets')
    task = Rake::Task['onelink:audits:redact_channel_secrets']
    task.reenable
    output = StringIO.new
    $stdout = output
    with_modified_env(env.transform_values(&:to_s)) { task.invoke }
    output.string
  ensure
    $stdout = STDOUT
  end

  it 'counts per inbox and key on a dry run, prints no value and changes nothing' do
    before = [session_row_id, string_row_id, clean_row_id].map { |id| stored(id) }

    output = run_task

    expect(output).to include(
      { inbox_id: inbox.id, account_id: inbox.account_id, rows: 2, keys: { 'api_hash' => 1, 'runtime_state' => 1, 'string_session' => 1 } }.to_json
    )
    expect(output).to include('"mode":"dry_run"', '"rows":2', '"inboxes":1')
    expect(output).not_to include(session, 'stored-login-token', 'stored-old-hash', '+7701')
    expect([session_row_id, string_row_id, clean_row_id].map { |id| stored(id) }).to eq(before)
  end

  it 'filters the stored entries in place with APPLY=1, keeps their storage form and is idempotent' do
    clean_before = stored(clean_row_id)

    expect(run_task(APPLY: '1')).to include('"mode":"applied"', '"rows":2')

    object_row = stored(session_row_id)
    expect(object_row['storage']).to eq('object')
    # The snapshot change held no setting of the operator: it is left out, as the write path leaves it out
    expect(JSON.parse(object_row['raw'])).to eq(
      'string_session' => [nil, '[FILTERED]'],
      'phone_number' => ['+77010000001', '+77010000002']
    )

    string_row = stored(string_row_id)
    expect(string_row['storage']).to eq('string')
    expect(JSON.parse(JSON.parse(string_row['raw']))).to eq('api_hash' => ['[FILTERED]', '[FILTERED]'])
    expect(stored(clean_row_id)).to eq(clean_before)

    expect(run_task(APPLY: '1')).to include('"rows":0')
  end

  it 'keeps who turned group sync or an ignored chat on or off, without the rest of the snapshot' do
    snapshot = {
      'qr_login_url' => 'tg://login?token=stored-login-token', 'history_sync_checkpoint' => { 'dialog_user_ids' => %w[700100] },
      'sync_groups' => false, 'ignored_chat_ids' => []
    }
    toggle_row_id = insert_audit(inbox, { 'runtime_state' => [snapshot, snapshot.merge('sync_groups' => true, 'ignored_chat_ids' => ['555'])] })

    described_class.new(apply: true).perform

    expect(JSON.parse(stored(toggle_row_id)['raw'])).to eq(
      'runtime_state' => [{ 'ignored_chat_ids' => [], 'sync_groups' => false }, { 'ignored_chat_ids' => ['555'], 'sync_groups' => true }]
    )
    expect(stored(toggle_row_id)['raw']).not_to include('stored-login-token', '700100')
    expect(described_class.new(apply: true, inbox_ids: [inbox.id]).perform.rows).to eq(0)
  end

  it 'touches only the inboxes it is given' do
    other_inbox = create(:channel_telegram_personal).inbox
    other_row_id = insert_audit(other_inbox, object_changes)

    report = described_class.new(apply: true, inbox_ids: [other_inbox.id.to_s], batch_size: 1).perform

    expect(report.rows).to eq(1)
    expect(report.inboxes.keys).to eq([other_inbox.id])
    expect(JSON.parse(stored(other_row_id)['raw'])['string_session']).to eq([nil, '[FILTERED]'])
    expect(JSON.parse(stored(session_row_id)['raw'])['string_session']).to eq([nil, session])
  end
end
