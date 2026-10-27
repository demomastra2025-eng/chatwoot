require 'rails_helper'

RSpec.describe Reminders::NotificationsReleaseService do
  describe '#backfill_rule' do
    let(:rule) { instance_double(AutomationRule, updated_at: Time.current) }
    let(:rules) { instance_double(ActiveRecord::Associations::CollectionProxy, find: rule) }
    let(:account) { instance_double(Account, id: 7, automation_rules: rules) }
    let(:planner) do
      instance_double(Reminders::BackfillAutomationRuleEnrollmentsService, plan: [
                        { appointment_id: 11, action_id: 'fake-action', due_at: 1.day.from_now, kind: 'direct' }
                      ])
    end

    before do
      allow(Account).to receive(:find).with('7').and_return(account)
      allow(Reminders::BackfillAutomationRuleEnrollmentsService).to receive(:new).and_return(planner)
      allow(planner).to receive(:perform)
    end

    it 'prints only ids and counts in preview and does not perform the plan' do
      with_modified_env(APPLY: nil, ACCOUNT_ID: '7', RULE_ID: '9') do
        expect { puts described_class.new.backfill_rule }.to output("account_id=7 count=1 appointment_ids=11\n").to_stdout
      end
      expect(planner).not_to have_received(:perform)
    end

    it 'requires confirmation and an existing backup directory before apply' do
      with_modified_env(APPLY: '1', CONFIRM: nil, BACKUP_DIR: nil, ACCOUNT_ID: '7', RULE_ID: '9') do
        expect { described_class.new.backfill_rule }.to raise_error(ArgumentError, /CONFIRM=yes/)
      end
    end
  end
end
