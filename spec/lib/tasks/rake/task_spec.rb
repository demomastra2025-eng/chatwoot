require 'rails_helper'
require 'rake'

RSpec.describe Rake::Task do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before do
    Rails.application.load_tasks unless described_class.task_defined?('medelement:delta_misses')
  end

  it 'prints a code hash and field names without the raw reception code' do
    Integrations::Medelement::DeltaMiss.create!(
      hook: hook, reception_code: 'fake-reception-code', change_marker: 'marker-1',
      kind: 'changed', classification: 'unexplained', changed_fields: %w[starts_at],
      detected_at: Time.current
    )
    task = described_class['medelement:delta_misses']
    task.reenable

    expect { task.invoke(hook.id, 7) }.to output(/changed \| unexplained \| starts_at/).to_stdout
    task.reenable
    expect { task.invoke(hook.id, 7) }.not_to output(/fake-reception-code/).to_stdout
  end
end
