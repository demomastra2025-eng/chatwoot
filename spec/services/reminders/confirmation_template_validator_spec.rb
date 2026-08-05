require 'rails_helper'

RSpec.describe Reminders::ConfirmationTemplateValidator do
  let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:template_params) { { name: 'appointment_confirmation', language: 'ru' } }

  it 'accepts an approved template with exactly one quick-reply button at index zero' do
    set_template_buttons([{ 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' }])

    expect(validator).to be_valid
  end

  it 'rejects templates without buttons, with multiple buttons, or with a non-quick-reply button' do
    invalid_button_sets = [
      [],
      [
        { 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' },
        { 'type' => 'QUICK_REPLY', 'text' => 'Перенести' }
      ],
      [{ 'type' => 'URL', 'text' => 'Открыть', 'url' => 'https://example.com' }]
    ]

    invalid_button_sets.each do |buttons|
      set_template_buttons(buttons)
      expect(validator).not_to be_valid
    end
  end

  it 'rejects a foreign-account inbox and a nonzero button index' do
    set_template_buttons([{ 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' }])

    expect(
      described_class.new(
        account: create(:account),
        inbox: channel.inbox,
        template_params: template_params,
        button_index: 0
      )
    ).not_to be_valid
    expect(
      described_class.new(
        account: account,
        inbox: channel.inbox,
        template_params: template_params,
        button_index: 1
      )
    ).not_to be_valid
  end

  def validator
    described_class.new(
      account: account,
      inbox: channel.inbox,
      template_params: template_params,
      button_index: 0
    )
  end

  def set_template_buttons(buttons)
    channel.update!(
      message_templates: [
        {
          'name' => template_params[:name],
          'language' => template_params[:language],
          'status' => 'APPROVED',
          'components' => [
            { 'type' => 'BODY', 'text' => 'Подтвердите запись' },
            { 'type' => 'BUTTONS', 'buttons' => buttons }
          ]
        }
      ]
    )
  end
end
