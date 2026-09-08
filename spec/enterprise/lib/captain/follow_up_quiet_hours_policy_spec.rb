require 'rails_helper'

RSpec.describe Captain::FollowUpQuietHoursPolicy do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, timezone: 'Asia/Almaty') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:assistant) { create(:captain_assistant, account: account, config: config) }
  let(:config) do
    {
      'follow_up_settings' => {
        'quiet_hours' => { 'enabled' => true }
      }
    }
  end
  let(:almaty) { Time.find_zone!('Asia/Almaty') }

  it 'uses default boundaries and moves a nightly follow-up to 08:00 local time' do
    result = described_class.new(
      assistant: assistant,
      conversation: conversation,
      now: almaty.local(2026, 9, 5, 2, 30)
    ).call

    expect(result).to be_quiet
    expect(result.timezone).to eq('Asia/Almaty')
    expect(result.next_allowed_at).to eq(almaty.local(2026, 9, 5, 8, 0).utc)
  end

  it 'moves a follow-up after the evening boundary to the next local morning' do
    result = described_class.new(
      assistant: assistant,
      conversation: conversation,
      now: almaty.local(2026, 9, 5, 23, 30)
    ).call

    expect(result).to be_quiet
    expect(result.next_allowed_at).to eq(almaty.local(2026, 9, 6, 8, 0).utc)
  end

  it 'supports business-specific hours and timezone' do
    config.merge!(
      'follow_up_settings' => {
        'quiet_hours' => {
          'enabled' => true,
          'start_time' => '21:00',
          'end_time' => '09:00',
          'timezone' => 'Europe/Warsaw'
        }
      }
    )
    warsaw = Time.find_zone!('Europe/Warsaw')

    result = described_class.new(
      assistant: assistant,
      conversation: conversation,
      now: warsaw.local(2026, 9, 5, 22, 0)
    ).call

    expect(result).to be_quiet
    expect(result.timezone).to eq('Europe/Warsaw')
    expect(result.next_allowed_at).to eq(warsaw.local(2026, 9, 6, 9, 0).utc)
  end

  it 'can be disabled by the business' do
    config.merge!('follow_up_settings' => { 'quiet_hours' => { 'enabled' => false } })

    result = described_class.new(
      assistant: assistant,
      conversation: conversation,
      now: almaty.local(2026, 9, 5, 2, 30)
    ).call

    expect(result).not_to be_quiet
  end
end
