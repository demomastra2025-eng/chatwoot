require 'rails_helper'

RSpec.describe Channel::LinkedinPersonal do
  around do |example|
    with_modified_env('FRONTEND_URL' => 'https://app.example.com') do
      example.run
    end
  end

  describe 'defaults and derived fields' do
    it 'generates webhook credentials and callback url' do
      channel = create(:channel_linkedin_personal, profile_urn: 'urn:li:fsd_profile:ABC123', display_name: 'Sales LinkedIn')

      expect(channel.generated_inbox_name).to eq('Sales LinkedIn')
      expect(channel.webhook_identifier).to be_present
      expect(channel.webhook_secret).to be_present
      expect(channel.callback_webhook_url).to eq(
        "https://app.example.com/webhooks/linkedin_personal/#{channel.webhook_identifier}"
      )
    end
  end

  describe 'runtime identity updates' do
    it 'does not allow changing profile_urn after creation' do
      channel = create(:channel_linkedin_personal)

      expect(channel.update(profile_urn: 'urn:li:fsd_profile:OTHER')).to be(false)
      expect(channel.errors[:profile_urn]).to include('cannot be changed after creation')
    end
  end

  describe 'multitenant uniqueness' do
    it 'allows the same profile urn in different accounts' do
      first = create(:channel_linkedin_personal)
      second = build(:channel_linkedin_personal, account: create(:account), profile_urn: first.profile_urn)

      expect(second).to be_valid
    end

    it 'does not allow the same profile urn twice in the same account' do
      account = create(:account)
      create(:channel_linkedin_personal, account: account, profile_urn: 'urn:li:fsd_profile:ABC')
      duplicate = build(:channel_linkedin_personal, account: account, profile_urn: 'urn:li:fsd_profile:ABC')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:profile_urn]).to be_present
    end
  end

  describe 'credential validation' do
    it 'requires li_at session cookie' do
      channel = described_class.new(account: create(:account), profile_urn: 'urn:li:fsd_profile:ABC')

      expect(channel).not_to be_valid
      expect(channel.errors[:li_at]).to include('must be present')
    end
  end

  describe 'runtime lifecycle helpers' do
    it 'normalizes runtime_state updates received from the gateway' do
      channel = create(:channel_linkedin_personal)

      channel.apply_runtime_update!(
        runtime_state: {
          history_sync_count: '7',
          history_thread_count: '2',
          contacts_sync_count: '3'
        }
      )
      channel.reload

      expect(channel.runtime_state['history_sync_count']).to eq(7)
      expect(channel.runtime_state['history_thread_count']).to eq(2)
      expect(channel.runtime_state['contacts_sync_count']).to eq(3)
      expect(channel.runtime_state).to have_key('history_sync_state')
    end
  end
end
