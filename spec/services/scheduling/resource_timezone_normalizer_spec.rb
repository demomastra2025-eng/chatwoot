# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduling::ResourceTimezoneNormalizer do
  describe '.perform' do
    it 'normalizes resources to each workspace timezone and uses the default for invalid legacy settings' do
      almaty_account = create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' })
      new_york_account = create(:account, settings: { 'workspace_timezone' => 'America/New_York' })
      invalid_account = create(:account)

      almaty_resource = create(:scheduling_resource, account: almaty_account)
      new_york_resource = create(:scheduling_resource, account: new_york_account)
      invalid_resource = create(:scheduling_resource, account: invalid_account)
      invalid_account.update_column(
        :settings,
        invalid_account.settings.merge('workspace_timezone' => 'Invalid/Timezone')
      )
      almaty_resource.update_column(:timezone, 'UTC')
      new_york_resource.update_column(:timezone, 'UTC')
      invalid_resource.update_column(:timezone, 'UTC')

      result = described_class.perform

      expect(result).to eq(
        mismatches_before: 3,
        rows_updated: 3,
        mismatches_after: 0
      )
      expect(almaty_resource.reload.timezone).to eq('Asia/Almaty')
      expect(new_york_resource.reload.timezone).to eq('America/New_York')
      expect(invalid_resource.reload.timezone).to eq(AccountWorkspaceWorkingHours::DEFAULT_TIMEZONE)
      expect(invalid_account.reload.workspace_working_hours_timezone).to eq(
        AccountWorkspaceWorkingHours::DEFAULT_TIMEZONE
      )
      expect { invalid_account.workspace_open_at?(Time.current) }.not_to raise_error

      invalid_resource.update!(name: 'Still normalized')
      expect(invalid_resource.reload.timezone).to eq(AccountWorkspaceWorkingHours::DEFAULT_TIMEZONE)
    end

    it 'is idempotent when resource timezones already match workspace settings' do
      account = create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' })
      create(:scheduling_resource, account: account)

      expect(described_class.perform).to eq(
        mismatches_before: 0,
        rows_updated: 0,
        mismatches_after: 0
      )
    end
  end
end
