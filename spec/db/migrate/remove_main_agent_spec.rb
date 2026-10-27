require 'rails_helper'
require Rails.root.join('db/migrate/20261027150000_remove_main_agent')

RSpec.describe RemoveMainAgent do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let!(:first_agent) { create(:captain_assistant, account: account) }
  let!(:second_agent) { create(:captain_assistant, account: account) }
  let!(:other_agent) { create(:captain_assistant, account: other_account) }
  let(:first_inbox) { create(:inbox, account: account) }
  let(:second_inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: other_account) }
  let(:voice_inbox) { create_voice_inbox(account) }
  let(:backups) { Class.new(ApplicationRecord) { self.table_name = 'captain_main_agent_backups' } }

  def whatsapp_inbox(ai_voice:)
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false,
                              provider_config: { 'ai_voice_enabled' => ai_voice }).inbox
  end

  def run(direction)
    ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
  end

  def default_of(record)
    record.reload.settings['captain_default_assistant_id']
  end

  def rows
    CaptainInbox.where(inbox_id: [first_inbox.id, second_inbox.id, other_inbox.id, voice_inbox.id]).order(:inbox_id).to_h do |row|
      [row.inbox_id, [row.captain_assistant_id, row.ai_enabled, row.auto_reply_mode]]
    end
  end

  # The state before the migration: a main agent per account and an agent on every text row. The test database already has the new
  # shape, so the spec brings it back with `down` first.
  before do
    run(:down)
    account.update!(settings: account.settings.to_h.merge('captain_default_assistant_id' => first_agent.id, 'workspace_timezone' => 'UTC'))
    other_account.update!(settings: other_account.settings.to_h.merge('captain_default_assistant_id' => other_agent.id))
    CaptainInbox.new(inbox: first_inbox, captain_assistant_id: first_agent.id, ai_enabled: true).save!(validate: false)
    CaptainInbox.new(inbox: second_inbox, captain_assistant_id: second_agent.id, ai_enabled: false, auto_reply_mode: 'working_hours')
                .save!(validate: false)
    CaptainInbox.new(inbox: other_inbox, captain_assistant_id: other_agent.id, ai_enabled: true).save!(validate: false)
    CaptainInbox.new(inbox: voice_inbox, captain_assistant_id: second_agent.id, ai_enabled: true).save!(validate: false)
  end

  describe '#up' do
    it 'removes the agent from every text row and the default agent from every account, and keeps the voice row as it is' do
      run(:up)

      expect(rows).to eq(
        first_inbox.id => [nil, true, 'always'],
        second_inbox.id => [nil, false, 'working_hours'],
        other_inbox.id => [nil, true, 'always'],
        voice_inbox.id => [second_agent.id, true, 'always']
      )
      expect(account.reload.settings).not_to have_key('captain_default_assistant_id')
      expect(other_account.reload.settings).not_to have_key('captain_default_assistant_id')
      expect(account.settings['workspace_timezone']).to eq('UTC')
    end

    it 'writes one backup row per account default and per text row, and none for a voice row' do
      run(:up)

      expect(backups.group(:kind).count).to eq('account_default' => 2, 'text_inbox_agent' => 3)
      expect(backups.where(kind: 'account_default').pluck(:account_id, :assistant_id))
        .to contain_exactly([account.id, first_agent.id], [other_account.id, other_agent.id])
      expect(backups.where(kind: 'text_inbox_agent').pluck(:inbox_id, :assistant_id))
        .to contain_exactly([first_inbox.id, first_agent.id], [second_inbox.id, second_agent.id], [other_inbox.id, other_agent.id])
      expect(backups.where(inbox_id: voice_inbox.id)).not_to exist
    end

    it 'keeps the agent of a WhatsApp number whose AI voice is on (its calls have no router) and removes the one of a text-only number' do
      calls = whatsapp_inbox(ai_voice: true)
      text_only = whatsapp_inbox(ai_voice: false)
      CaptainInbox.new(inbox: calls, captain_assistant_id: first_agent.id, ai_enabled: true).save!(validate: false)
      CaptainInbox.new(inbox: text_only, captain_assistant_id: first_agent.id, ai_enabled: true).save!(validate: false)

      run(:up)

      expect(CaptainInbox.find_by(inbox_id: calls.id).captain_assistant_id).to eq(first_agent.id)
      expect(CaptainInbox.find_by(inbox_id: text_only.id).captain_assistant_id).to be_nil
      expect(backups.where(inbox_id: calls.id)).not_to exist
      expect(backups.where(inbox_id: text_only.id).pluck(:assistant_id)).to eq([first_agent.id])
    end

    it 'lets a text row stay without an agent and a voice row still need one' do
      run(:up)

      expect(connection.columns(:captain_inboxes).find { |column| column.name == 'captain_assistant_id' }.null).to be(true)
    end

    it 'ignores an account whose default is empty or not a number' do
      other_account.update!(settings: other_account.settings.to_h.merge('captain_default_assistant_id' => nil))
      account.update!(settings: account.settings.to_h.merge('captain_default_assistant_id' => 'junk'))

      run(:up)

      expect(backups.where(kind: 'account_default')).not_to exist
      expect(account.reload.settings).not_to have_key('captain_default_assistant_id')
      expect(other_account.reload.settings).not_to have_key('captain_default_assistant_id')
    end
  end

  describe '#down' do
    it 'puts the same defaults and the same agents back, and drops the backups' do
      before_rows = rows
      run(:up)
      run(:down)

      expect(rows).to eq(before_rows)
      expect(default_of(account)).to eq(first_agent.id)
      expect(default_of(other_account)).to eq(other_agent.id)
      expect(account.settings['workspace_timezone']).to eq('UTC')
      expect(connection.table_exists?(:captain_main_agent_backups)).to be(false)
      expect(connection.columns(:captain_inboxes).find { |column| column.name == 'captain_assistant_id' }.null).to be(false)
    end

    it 'gives a text row made after the migration the default agent, else the lowest enabled agent, else removes the row' do
      run(:up)
      new_inbox = create(:inbox, account: account)
      CaptainInbox.create!(inbox: new_inbox, ai_enabled: true)
      lonely_inbox = create(:inbox)
      CaptainInbox.create!(inbox: lonely_inbox, ai_enabled: true)
      third_inbox = create(:inbox, account: other_account)
      CaptainInbox.create!(inbox: third_inbox, ai_enabled: true)
      other_agent.update!(active: false)

      run(:down)

      expect(CaptainInbox.find_by(inbox_id: new_inbox.id).captain_assistant_id).to eq(first_agent.id)
      expect(CaptainInbox.find_by(inbox_id: lonely_inbox.id)).to be_nil
      expect(CaptainInbox.find_by(inbox_id: third_inbox.id)).to be_nil
    end

    it 'does not give back an agent that was removed or disabled in between: the lowest enabled agent takes its place' do
      run(:up)
      first_agent.update!(active: false)

      run(:down)

      expect(default_of(account)).to eq(second_agent.id)
      expect(CaptainInbox.find_by(inbox_id: first_inbox.id).captain_assistant_id).to eq(first_agent.id)
    end
  end

  it 'gives the same state when it runs again after a rollback' do
    run(:up)
    first_pass = [rows, backups.order(:kind, :account_id, :inbox_id).pluck(:kind, :account_id, :inbox_id, :assistant_id),
                  account.reload.settings, other_account.reload.settings]
    run(:down)
    run(:up)

    second_pass = [rows, backups.order(:kind, :account_id, :inbox_id).pluck(:kind, :account_id, :inbox_id, :assistant_id),
                   account.reload.settings, other_account.reload.settings]
    expect(second_pass).to eq(first_pass)
  end
end
