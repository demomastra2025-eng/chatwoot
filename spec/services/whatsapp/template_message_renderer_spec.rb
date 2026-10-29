# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::TemplateMessageRenderer do
  let(:account) { create(:account) }
  let(:whatsapp_channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      message_templates: [
        {
          'id' => 'tpl_1',
          'name' => 'dostarmed_visit_reminder_bilingual_v2',
          'language' => 'ru',
          'status' => 'APPROVED',
          'category' => 'UTILITY',
          'components' => [
            { 'type' => 'HEADER', 'format' => 'TEXT', 'text' => 'Клиника {{1}}' },
            {
              'type' => 'BODY',
              'text' => "Сәлеметсіз бе, {{1}}!\nДәрігер: {{2}}\n--------------------\nЗдравствуйте, {{1}}!\nВрач: {{2}}"
            },
            { 'type' => 'FOOTER', 'text' => 'Ждём вас' },
            {
              'type' => 'BUTTONS',
              'buttons' => [
                { 'type' => 'QUICK_REPLY', 'text' => 'Растаймын | Подтверждаю' },
                { 'type' => 'URL', 'text' => '2ГИС маршрут', 'url' => 'https://2gis.kz/{{1}}' }
              ]
            }
          ]
        }
      ]
    )
  end

  describe '#render_text and #render_buttons' do
    it 'renders HEADER, BODY, FOOTER with processed_params and extracts buttons' do
      tp = {
        'name' => 'dostarmed_visit_reminder_bilingual_v2',
        'language' => 'ru',
        'category' => 'UTILITY',
        'processed_params' => {
          'header' => { '1' => 'Dostarmed' },
          'body' => { '1' => 'Асет', '2' => 'Иванов И.И.' },
          'buttons' => [{ 'type' => 'url', 'parameter' => 'almaty' }]
        }
      }

      renderer = described_class.new(channel: whatsapp_channel, template_params: tp)

      expect(renderer.render_text).to eq(
        "Клиника Dostarmed\n\nСәлеметсіз бе, Асет!\nДәрігер: Иванов И.И.\n--------------------\nЗдравствуйте, Асет!\nВрач: Иванов И.И.\n\nЖдём вас"
      )
      expect(renderer.render_buttons).to eq([
                                              { 'type' => 'QUICK_REPLY', 'text' => 'Растаймын | Подтверждаю' },
                                              { 'type' => 'URL', 'text' => '2ГИС маршрут' }
                                            ])
    end

    it 'supports legacy flat processed_params and normalized language subtags' do
      tp = {
        'name' => 'dostarmed_visit_reminder_bilingual_v2',
        'language' => 'ru_RU',
        'processed_params' => { '1' => 'Марат', '2' => 'Сериков С.С.' }
      }

      renderer = described_class.new(channel: whatsapp_channel, template_params: tp)
      expect(renderer.render_text).to include('Здравствуйте, Марат!')
      expect(renderer.render_text).to include('Врач: Сериков С.С.')
    end
  end

  describe 'Messages::MessageBuilder integration' do
    let(:inbox) { whatsapp_channel.inbox }
    let(:contact) { create(:contact, account: account, phone_number: '+77010001122') }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77010001122') }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
    let(:user) { create(:user, account: account, role: :administrator) }

    it 'populates message.content and additional_attributes.template_buttons when content is blank' do
      params = ActionController::Parameters.new(
        content: '',
        template_params: {
          'name' => 'dostarmed_visit_reminder_bilingual_v2',
          'language' => 'ru',
          'category' => 'UTILITY',
          'processed_params' => {
            'header' => { '1' => 'Dostarmed' },
            'body' => { '1' => 'Алия', '2' => 'Кемерова А.К.' }
          }
        }
      )

      msg = Messages::MessageBuilder.new(user, conversation, params, skip_send_reply: true, skip_delivery_policy: true).perform

      expect(msg.content).to include('Здравствуйте, Алия!')
      expect(msg.content).to include('Врач: Кемерова А.К.')
      expect(msg.additional_attributes['template_buttons']).to eq([
                                                                    { 'type' => 'QUICK_REPLY', 'text' => 'Растаймын | Подтверждаю' },
                                                                    { 'type' => 'URL', 'text' => '2ГИС маршрут' }
                                                                  ])
    end

    it 'renders Reminder#renderable_body when reminder.body is blank and language did not switch' do
      reminder = Reminder.new(
        account: account,
        target_inbox: inbox,
        target_contact: contact,
        remindable: conversation,
        action_type: 'send_message',
        content_kind: 'channel_template',
        body: '',
        template_params: {
          'name' => 'dostarmed_visit_reminder_bilingual_v2',
          'language' => 'ru',
          'category' => 'UTILITY',
          'processed_params' => {
            'header' => { '1' => 'Dostarmed' },
            'body' => { '1' => 'Данияр', '2' => 'Еркенов А.' }
          }
        }
      )

      rendered = reminder.renderable_body(conversation: conversation, sender: user)
      expect(rendered).to include('Здравствуйте, Данияр!')
      expect(rendered).to include('Врач: Еркенов А.')
    end
  end
end
