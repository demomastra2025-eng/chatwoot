require 'rails_helper'

RSpec.describe Inbox::RuntimeStatePresenter do
  let(:channel) do
    create(
      :channel_telegram_personal,
      runtime_state: {
        history_sync_state: 'running',
        history_sync_mode: 'full',
        history_sync_last_completed_dialog_id: '6002671687',
        qr_login_url: 'tg://login?token=secret-qr',
        ignored_chat_ids: ['12345'],
        history_sync_checkpoint: {
          version: 3,
          mode: 'full',
          dialog_user_ids: %w[6002671687 23],
          failed_dialog_ids: ['6002671687'],
          next_dialog_index: 1,
          last_completed_dialog_id: '6002671687',
          dialog_cursors: { '6002671687' => { 'done' => true, 'min_id' => 1 } }
        }
      }
    )
  end

  it 'strips dialog_user_ids, failed_dialog_ids, last_completed_dialog_id, dialog_cursors, and top-level dialog id leaks' do
    admin_view = described_class.for(channel, administrator: true)
    agent_view = described_class.for(channel, administrator: false)

    [admin_view, agent_view].each do |view|
      expect(view.to_json).not_to include('6002671687')
      expect(view).not_to have_key('history_sync_last_completed_dialog_id')
      expect(view['history_sync_checkpoint'].keys).not_to include(
        'dialog_user_ids',
        'failed_dialog_ids',
        'last_completed_dialog_id',
        'dialog_cursors'
      )
      expect(view.dig('history_sync_checkpoint', 'next_dialog_index')).to eq(1)
    end

    expect(admin_view).to include('qr_login_url' => 'tg://login?token=secret-qr', 'ignored_chat_ids' => ['12345'])
    expect(agent_view).not_to include('qr_login_url', 'ignored_chat_ids')
  end

  it 'strips top-level and nested dialog ids and secrets from telegram_personal_diagnostics' do
    sanitized = described_class.telegram_personal_diagnostics(
      connected: true,
      history_sync_last_completed_dialog_id: '6002671687',
      string_session: '1BV-top-secret',
      channel: {
        string_session: '1BV-nested-secret',
        pending_phone_code_hash: 'code-hash',
        history_sync_last_completed_dialog_id: '6002671687',
        runtime_state: channel.runtime_state_payload
      }
    )

    expect(sanitized.to_json).not_to include('6002671687')
    expect(sanitized.to_json).not_to include('1BV-')
    expect(sanitized).not_to have_key('history_sync_last_completed_dialog_id')
    expect(sanitized['channel']).not_to have_key('history_sync_last_completed_dialog_id')
  end
end
