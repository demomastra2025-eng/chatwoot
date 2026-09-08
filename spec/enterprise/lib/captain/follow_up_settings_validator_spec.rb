require 'rails_helper'

RSpec.describe Captain::FollowUpSettingsValidator do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  it 'rejects invalid quiet hours at the model boundary' do
    assistant.config = assistant.config.to_h.merge(
      'follow_up_settings' => {
        'enabled' => true,
        'quiet_hours' => {
          'enabled' => true,
          'start_time' => '25:00',
          'end_time' => '25:00',
          'timezone' => 'Not/AZone'
        },
        'steps' => [{ 'delay_seconds' => 3600, 'mode' => 'static', 'message' => 'Follow up' }]
      }
    )

    expect(assistant).not_to be_valid
    expect(assistant.errors[:config]).to include(
      'quiet_hours start_time is invalid',
      'quiet_hours end_time is invalid',
      'quiet_hours start_time and end_time must differ',
      'quiet_hours timezone is invalid'
    )
  end

  it 'ignores stale template settings for an inbox no longer connected to the assistant' do
    assistant.config = assistant.config.to_h.merge(
      'follow_up_settings' => {
        'enabled' => true,
        'steps' => [
          {
            'delay_seconds' => 3600,
            'mode' => 'static',
            'message' => 'Follow up',
            'template_variants_by_inbox' => {
              '999999' => {
                'ru' => { 'name' => 'follow_up_ru', 'language' => 'ru' }
              }
            }
          }
        ]
      }
    )

    expect(assistant).to be_valid
  end

  it 'rejects a template that is not approved in the connected inbox catalog' do
    inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
    assistant.inboxes << inbox
    assistant.config = assistant.config.to_h.merge(
      'follow_up_settings' => {
        'enabled' => true,
        'steps' => [
          {
            'delay_seconds' => 3600,
            'mode' => 'static',
            'message' => 'Follow up',
            'template_variants_by_inbox' => {
              inbox.id.to_s => {
                'ru' => { 'name' => 'not_approved', 'language' => 'ru', 'processed_params' => {} }
              }
            }
          }
        ]
      }
    )

    expect(assistant).not_to be_valid
    expect(assistant.errors[:config].join(' ')).to include('Approved channel template was not found')
  end

  it 'rejects a template whose language does not match the variant key' do
    inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
    assistant.inboxes << inbox
    assistant.config = assistant.config.to_h.merge(
      'follow_up_settings' => {
        'enabled' => true,
        'steps' => [
          {
            'delay_seconds' => 3600,
            'mode' => 'static',
            'message' => 'Follow up',
            'template_variants_by_inbox' => {
              inbox.id.to_s => {
                'ru' => { 'name' => 'follow_up_en', 'language' => 'en_US', 'processed_params' => {} }
              }
            }
          }
        ]
      }
    )

    expect(assistant).not_to be_valid
    expect(assistant.errors[:config]).to include('follow_up step 1 ru: template language does not match variant')
  end

  it 'accepts a valid follow-up schedule without channel templates' do
    assistant.config = assistant.config.to_h.merge(
      'follow_up_settings' => {
        'enabled' => true,
        'quiet_hours' => {
          'enabled' => true,
          'start_time' => '23:00',
          'end_time' => '08:00',
          'timezone' => 'Asia/Almaty'
        },
        'steps' => [{ 'delay_seconds' => 3600, 'mode' => 'static', 'message' => 'Follow up' }]
      }
    )

    expect(assistant).to be_valid
  end
end
