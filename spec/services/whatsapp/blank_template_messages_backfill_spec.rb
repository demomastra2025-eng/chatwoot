# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::BlankTemplateMessagesBackfill do
  let(:account) { create(:account, limits: { 'non_web_inboxes' => 10 }) }
  let(:whatsapp_channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      message_templates: [
        {
          'id' => 'tpl_backfill_1',
          'name' => 'dostarmed_visit_reminder_bilingual_v2',
          'language' => 'ru',
          'status' => 'APPROVED',
          'category' => 'UTILITY',
          'components' => [
            {
              'type' => 'BODY',
              'text' => "Сәлеметсіз бе, {{1}}!\n--------------------\nЗдравствуйте, {{1}}!"
            },
            {
              'type' => 'BUTTONS',
              'buttons' => [
                { 'type' => 'QUICK_REPLY', 'text' => 'Растаймын | Подтверждаю' }
              ]
            }
          ]
        }
      ]
    )
  end
  let(:inbox) { whatsapp_channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+77019998877') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77019998877') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:legacy_additional_attributes) do
    {
      'touch_id' => 999,
      'template_params' => {
        'name' => 'dostarmed_visit_reminder_bilingual_v2',
        'language' => 'ru',
        'category' => 'UTILITY',
        'processed_params' => { 'body' => { '1' => 'Клиент' } }
      }
    }
  end

  def create_legacy_blank_template_message
    msg = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :outgoing,
      content: 'placeholder',
      additional_attributes: legacy_additional_attributes
    )
    Message.where(id: msg.id).update_all(content: '') # rubocop:disable Rails/SkipsModelValidations
    msg.reload
  end

  it 'reports counts without modifying messages in dry_run mode' do
    msg = create_legacy_blank_template_message

    result = described_class.new(apply: false, account_id: account.id).perform

    expect(result[:mode]).to eq('dry_run')
    expect(result[:totals]).to include(total: 1, matched: 1, with_buttons: 1, updated: 0)
    expect(msg.reload.content).to eq('')
  end

  it 'populates content and template_buttons and writes a JSON backup in apply mode' do
    msg = create_legacy_blank_template_message

    Dir.mktmpdir do |tmpdir|
      backup_path = File.join(tmpdir, 'backup.json')
      result = described_class.new(apply: true, backup_file: backup_path, account_id: account.id).perform

      expect(result[:totals]).to include(total: 1, matched: 1, with_buttons: 1, updated: 1)
      expect(File.exist?(backup_path)).to be(true)
      expect(msg.reload.content).to eq("Сәлеметсіз бе, Клиент!\n--------------------\nЗдравствуйте, Клиент!")
      expect(msg.additional_attributes['template_buttons']).to eq(
        [{ 'type' => 'QUICK_REPLY', 'text' => 'Растаймын | Подтверждаю' }]
      )
    end
  end

  it 'restores original blank content and attributes from the JSON backup file' do
    msg = create_legacy_blank_template_message

    Dir.mktmpdir do |tmpdir|
      backup_path = File.join(tmpdir, 'backup.json')
      described_class.new(apply: true, backup_file: backup_path, account_id: account.id).perform
      restore_result = described_class.new(apply: true, restore_file: backup_path).perform

      expect(restore_result).to eq(mode: 'restore', restored: 1, total_in_backup: 1)
      expect(msg.reload.content).to eq('')
      expect(msg.additional_attributes).not_to have_key('template_buttons')
      expect(msg.additional_attributes['touch_id']).to eq(999)
    end
  end
end
