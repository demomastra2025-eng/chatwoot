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

  describe 'onelink:captain_settings:move_message_guidance' do
    let(:task) { Rake::Task['onelink:captain_settings:move_message_guidance'] }
    let(:handoff_message) { Captain::AccountSettings.new(account.reload).section('handoff')['handoff_message'] }

    before do
      task.reenable
      Captain::AccountSettings.new(account).update!(
        'handoff' => { 'handoff_message' => { 'enabled' => true, 'mode' => 'generated', 'text' => 'Секретные пожелания', 'instruction' => '' } }
      )
    end

    after { ENV.delete('DRY_RUN') }

    it 'lists the account and the message names on a dry run, never the texts, and changes nothing' do
      ENV['DRY_RUN'] = '1'

      expect { task.invoke }
        .to output(/\A(?!.*Секретные).*"account_id":#{account.id},"status":"would_move","messages":\["handoff_message"\]/m).to_stdout
      expect(handoff_message).to include('text' => 'Секретные пожелания', 'instruction' => '')
    end

    it 'moves the wishes into the instruction and prints no text' do
      expect { task.invoke }.to output(/\A(?!.*Секретные).*"account_id":#{account.id},"status":"moved"/m).to_stdout
      expect(handoff_message).to include('text' => '', 'instruction' => 'Секретные пожелания')
    end

    it 'prints nothing for the account on a second run' do
      task.invoke
      task.reenable

      expect { task.invoke }.not_to output(/"account_id":#{account.id}/).to_stdout
    end
  end
end
