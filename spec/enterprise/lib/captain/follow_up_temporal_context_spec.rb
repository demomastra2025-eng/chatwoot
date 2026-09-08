require 'rails_helper'

RSpec.describe Captain::FollowUpTemporalContext do
  let(:account) { create(:account, locale: 'ru') }
  let(:inbox) { create(:inbox, account: account, timezone: 'UTC') }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      additional_attributes: { 'conversation_language' => 'kk-KZ' }
    )
  end
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      config: {
        'follow_up_settings' => {
          'quiet_hours' => { 'enabled' => true, 'timezone' => 'Asia/Almaty' }
        }
      }
    )
  end
  let(:almaty) { Time.find_zone!('Asia/Almaty') }

  it 'uses the quiet-hours timezone for language, day period and relative date context' do
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'OK',
      created_at: almaty.local(2026, 9, 4, 17, 0)
    )

    context = described_class.new(
      conversation: conversation,
      assistant: assistant,
      now: almaty.local(2026, 9, 5, 8, 15)
    ).as_json

    expect(context).to include(
      language: 'kk',
      timezone: 'Asia/Almaty',
      day_period: 'morning',
      relative_day: 'yesterday'
    )
  end

  it 'uses a general earlier reference for old conversations' do
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      created_at: almaty.local(2026, 8, 20, 12, 0)
    )

    context = described_class.new(
      conversation: conversation,
      assistant: assistant,
      now: almaty.local(2026, 9, 5, 19, 0)
    ).as_json

    expect(context).to include(day_period: 'evening', relative_day: 'earlier')
  end
end
