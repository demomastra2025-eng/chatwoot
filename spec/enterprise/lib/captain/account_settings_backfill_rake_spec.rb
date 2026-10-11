require 'rails_helper'
require 'rake'

RSpec.describe Captain::AccountSettingsBackfill do
  let(:account) { create(:account) }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:captain_settings:conflicts')
    Rake::Task['onelink:captain_settings:conflicts'].reenable
  end

  it 'prints only account and agent IDs plus names of differing settings' do
    create(:captain_assistant, account: account, config: { 'feature_faq' => false })
    create(:captain_assistant, account: account, config: { 'feature_faq' => true, 'handoff_message' => 'Example private text' })

    expect { Rake::Task['onelink:captain_settings:conflicts'].invoke }
      .to output(/"account_id":#{account.id}.*"faq.generate_from_resolved"/).to_stdout
  end
end
