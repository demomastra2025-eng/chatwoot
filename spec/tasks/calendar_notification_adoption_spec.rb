require 'rails_helper'
require 'rake'
require 'tempfile'

RSpec.describe 'calendar_notifications:adopt' do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let!(:rule) do
    create(
      :automation_rule, account: account, event_name: 'appointment_created', active: false,
                        conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
                        actions: [{ action_name: 'create_touch', action_params: [{
                          action_type: 'send_message', content_kind: 'free_text', body: 'Visit message',
                          timing_mode: 'relative', relative_anchor: 'appointment.starts_at', relative_offset_seconds: -3600,
                          target_inbox_id: create(:inbox, account: account).id
                        }] }]
    )
  end

  before { Rails.application.load_tasks }

  it 'previews, backs up and marks the same rule without activating it' do
    task = Rake::Task['calendar_notifications:adopt']
    original_actions = rule.actions
    Tempfile.create(['calendar-adoption', '.json']) do |backup|
      with_modified_env(MODE: 'dry-run', BACKUP: backup.path) do
        task.reenable
        task.invoke
      end
      expect(rule.reload).not_to be_calendar_managed
      expect(JSON.parse(File.read(backup.path))).to include(include('id' => rule.id, 'account_id' => account.id))

      with_modified_env(MODE: 'apply', BACKUP: backup.path) do
        task.reenable
        task.invoke
      end
      expect(rule.reload).to be_calendar_managed
      expect(rule).not_to be_active
      expect(rule.actions).to eq(original_actions)
    end
  end
end
