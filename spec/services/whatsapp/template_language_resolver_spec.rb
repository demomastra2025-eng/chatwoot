# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::TemplateLanguageResolver do
  let(:account) { create(:account, settings: { 'client_languages' => %w[ru kk], 'bilingual_templates_enabled' => false }) }
  let(:whatsapp_channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false,
      message_templates: [
        {
          'id' => 'tpl_ru',
          'name' => 'appointment_created_confirm_ru',
          'status' => 'APPROVED',
          'category' => 'UTILITY',
          'language' => 'ru',
          'components' => [
            { 'type' => 'BODY', 'text' => 'Здравствуйте, {{1}}! Запись {{2}} в {{3}}, врач {{4}}. Подтвердите.' }
          ]
        },
        {
          'id' => 'tpl_kk',
          'name' => 'appointment_created_confirm_kk',
          'status' => 'APPROVED',
          'category' => 'UTILITY',
          'language' => 'kk',
          'components' => [
            { 'type' => 'BODY', 'text' => 'Сәлеметсіз бе, {{1}}! Жазылу {{2}} сағат {{3}}, дәрігер {{4}}. Растаңыз.' }
          ]
        }
      ]
    )
  end
  let(:inbox) { whatsapp_channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+77015554433') }
  let(:template_params) do
    {
      'name' => 'appointment_created_confirm_ru',
      'language' => 'ru',
      'category' => 'UTILITY',
      'processed_params' => {
        'body' => { '1' => 'Алия', '2' => '12 мая', '3' => '14:30', '4' => 'Айгуль' }
      }
    }
  end
  let(:reminder) do
    Reminder.new(
      account: account,
      target_inbox: inbox,
      target_contact: contact,
      content_kind: :channel_template,
      template_params: template_params
    )
  end

  it 'selects the APPROVED Kazakh template when contact client_language is kk' do
    contact.record_detected_language!('kk')

    resolved = described_class.new(reminder: reminder, template_params: template_params).call

    expect(resolved['name']).to eq('appointment_created_confirm_kk')
    expect(resolved['language']).to eq('kk')
    expect(contact.reload.client_language).to eq('kk')
    expect(contact.client_language_confidence).to eq(100)
    expect(reminder.renderable_body).to eq('Сәлеметсіз бе, Алия! Жазылу 12 мая сағат 14:30, дәрігер Айгуль. Растаңыз.')
  end

  it 'falls back to the clinic primary language when contact has no client_language' do
    account.update!(settings: account.settings.merge('client_languages' => %w[kk ru]))

    resolved = described_class.new(reminder: reminder, template_params: template_params).call

    expect(resolved['name']).to eq('appointment_created_confirm_kk')
    expect(resolved['language']).to eq('kk')
  end

  it 'keeps the configured template when bilingual_templates_enabled is true' do
    account.update!(settings: account.settings.merge('bilingual_templates_enabled' => true))
    contact.record_detected_language!('kk')

    resolved = described_class.new(reminder: reminder, template_params: template_params).call

    expect(resolved['name']).to eq('appointment_created_confirm_ru')
    expect(resolved['language']).to eq('ru')
  end
end
