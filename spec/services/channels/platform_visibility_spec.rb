# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channels::PlatformVisibility do
  let(:config_name) { described_class::CONFIG_NAME }
  let(:super_admin) { create(:super_admin) }

  def stored_value
    InstallationConfig.find_by(name: config_name)&.value
  end

  def audits
    Audited::Audit.where(auditable_type: 'InstallationConfig', action: described_class::AUDIT_ACTION)
  end

  describe '.settings and .state' do
    it 'follow the catalog defaults while the platform has no row' do
      expect(described_class.settings).to eq({})
      expect(described_class.state('api')).to eq('hidden')
      expect(described_class.state('website')).to eq('shown')
      expect(described_class.shown?('facebook')).to be(true)
      expect(described_class.shown?('tiktok')).to be(false)
    end

    it 'use what the row says' do
      upsert_installation_config(config_name, { 'api' => 'shown', 'website' => 'hidden' })

      expect(described_class.settings).to eq('api' => 'shown', 'website' => 'hidden')
      expect(described_class.state('api')).to eq('shown')
      expect(described_class.state('website')).to eq('hidden')
      expect(described_class.state('email')).to eq('shown')
    end

    it 'read a row stored as a JSON string' do
      upsert_installation_config(config_name, '{"line":"shown"}')

      expect(described_class.settings).to eq('line' => 'shown')
    end

    it 'ignore unknown channels, unknown states and a row that is not a map' do
      upsert_installation_config(config_name, { 'ghost' => 'shown', 'api' => 'maybe', 'sms' => 'shown' })
      expect(described_class.settings).to eq('sms' => 'shown')

      upsert_installation_config(config_name, 'not json at all')
      expect(described_class.settings).to eq({})

      upsert_installation_config(config_name, %w[api])
      expect(described_class.settings).to eq({})
      expect(described_class.state('api')).to eq('hidden')
    end
  end

  describe '.update!' do
    it 'stores only what differs from the default and returns the changes' do
      changes = described_class.update!({ 'api' => 'shown', 'website' => 'shown', 'sms' => 'hidden' })

      expect(changes).to eq('api' => { 'from' => 'hidden', 'to' => 'shown' })
      expect(stored_value).to eq('api' => 'shown')
      expect(InstallationConfig.find_by(name: config_name).locked).to be(false)
    end

    it 'keeps the channels that are not named' do
      described_class.update!({ 'api' => 'shown', 'website' => 'hidden' })
      described_class.update!({ 'sms' => 'shown' })

      expect(stored_value).to eq('api' => 'shown', 'website' => 'hidden', 'sms' => 'shown')
    end

    it 'removes the entry of a channel that goes back to its default' do
      described_class.update!({ 'api' => 'shown', 'website' => 'hidden' })

      changes = described_class.update!({ 'api' => 'hidden' })

      expect(changes).to eq('api' => { 'from' => 'shown', 'to' => 'hidden' })
      expect(stored_value).to eq('website' => 'hidden')
    end

    it 'writes nothing, creates no row and audits nothing when nothing changes' do
      expect(described_class.update!({ 'api' => 'hidden', 'website' => 'shown' }, actor: super_admin)).to eq({})

      expect(InstallationConfig.find_by(name: config_name)).to be_nil
      expect(audits).to be_empty
    end

    it 'leaves one audit entry with who changed what' do
      request = instance_double(ActionDispatch::Request, remote_ip: '10.0.0.7', request_id: 'req-1')

      described_class.update!({ 'api' => 'shown', 'tiktok' => 'shown' }, actor: super_admin, request: request)

      audit = audits.sole
      expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin', remote_address: '10.0.0.7')
      expect(audit.audited_changes['channels']).to eq(
        'api' => { 'from' => 'hidden', 'to' => 'shown' },
        'tiktok' => { 'from' => 'hidden', 'to' => 'shown' }
      )
    end

    it 'raises for an unknown channel or state and writes nothing' do
      expect { described_class.update!({ 'api' => 'shown', 'ghost' => 'shown' }) }
        .to raise_error(described_class::InvalidSettings, /unknown channel: ghost/)
      expect { described_class.update!({ 'api' => 'sometimes' }) }
        .to raise_error(described_class::InvalidSettings, /unknown state for api/)
      expect { described_class.update!('api') }.to raise_error(described_class::InvalidSettings)

      expect(InstallationConfig.find_by(name: config_name)).to be_nil
    end
  end

  describe '.updated_at' do
    it 'is nil until the settings are saved and then the time of the save' do
      expect(described_class.updated_at).to be_nil

      freeze_time do
        described_class.update!({ 'api' => 'shown' })

        expect(described_class.updated_at).to eq(Time.current)
      end
    end
  end
end
