require 'rails_helper'
require 'rake'

RSpec.describe TelegramPersonal::ServiceAccountPurge do
  let(:channel) { create(:channel_telegram_personal, runtime_state: { 'sync_groups' => true }) }
  let(:inbox) { channel.inbox }
  let(:service_contact_id) { inbox.contact_inboxes.find_by!(source_id: '777000').contact_id }

  # The way the importer took them in before the service account was skipped
  def import(target_inbox, peer_id, message_id, **data)
    TelegramPersonal::IncomingMessageService.new(
      inbox: target_inbox,
      params: { message_id: message_id, chat_id: peer_id, peer_user_id: peer_id, sender_id: peer_id, chat_type: 'private',
                first_name: 'Telegram', text: "Login code: 5#{message_id}" }.merge(data)
    ).perform
  end

  def run_task(**env)
    Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:telegram_personal:purge_service_account_chats')
    task = Rake::Task['onelink:telegram_personal:purge_service_account_chats']
    task.reenable
    output = StringIO.new
    $stdout = output
    with_modified_env(env.transform_values(&:to_s)) { task.invoke }
    output.string
  ensure
    $stdout = STDOUT
  end

  before do
    import(inbox, '777000', '801')
    import(inbox, '777000', '802')
    import(inbox, '23', '803', first_name: 'Aigerim', text: 'Hello')
    # A discussion group: 777000 is the sender of the posts its channel forwards there
    import(inbox, '-100500', '804', chat_type: 'supergroup', chat_title: 'Clinic news', peer_user_id: nil, sender_id: '777000', text: 'Post')
  end

  it 'counts the chat of the service account on a dry run, prints no text and changes nothing' do
    expect(inbox.messages.count).to eq(4)

    output = run_task

    expect(output).to include(
      { inbox_id: inbox.id, account_id: inbox.account_id, contact_inboxes: 1, conversations: 1, messages: 2, contacts: 1 }.to_json
    )
    expect(output).to include('"mode":"dry_run"')
    expect(output).not_to include('Login code', '5801')
    expect(inbox.messages.count).to eq(4)
    expect(inbox.contact_inboxes.count).to eq(3)
  end

  it 'deletes the chat and the contact of the service account with APPLY=1 and keeps a person and a group', :aggregate_failures do
    contact_id = service_contact_id

    expect(run_task(APPLY: '1')).to include('"mode":"applied"', '"messages":2', '"contacts":1')

    expect(inbox.contact_inboxes.pluck(:source_id)).to contain_exactly('23', '-100500')
    expect(inbox.messages.pluck(:content)).to contain_exactly('Hello', 'Post')
    expect(inbox.conversations.count).to eq(2)
    expect(Contact.exists?(contact_id)).to be(false)
    expect(run_task(APPLY: '1')).to include('"inboxes":0', '"messages":0')
  end

  it 'touches only the inboxes it is given and keeps a contact that has another inbox' do
    other_inbox = create(:channel_telegram_personal).inbox
    import(other_inbox, '777000', '901')
    create(:contact_inbox, contact: Contact.find(service_contact_id), inbox: create(:inbox, account: inbox.account), source_id: 'other')

    report = described_class.new(apply: true, inbox_ids: [inbox.id.to_s]).perform

    expect(report.inboxes.keys).to eq([inbox.id])
    expect(report.total(:contacts)).to eq(0)
    expect(Contact.exists?(service_contact_id)).to be(true)
    expect(inbox.contact_inboxes.pluck(:source_id)).not_to include('777000')
    expect(other_inbox.contact_inboxes.pluck(:source_id)).to eq(['777000'])
    expect(other_inbox.messages.count).to eq(1)
  end
end
