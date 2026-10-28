require 'rails_helper'
require 'rake'

RSpec.describe Integrations::Medelement::RequestTelemetry, '.report' do
  before do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
    Rake.application.rake_require('tasks/medelement_requests', [Rails.root.join('lib').to_s])
    Rake::Task['medelement:requests:report'].reenable
  end

  it 'prints hourly clinic, caller and first 429 request number' do
    rows = [{ hour: '2026102812', account_id: '11', hook_id: '22', lane: 'sync_far', operation: 'timetable',
              status: '429', count: 2, duration_ms: 70, first_429_at_count: 15,
              last_429_headers: '{}', last_429_hint: 'rate_limit' }]
    allow(described_class).to receive(:report).with(hours: 1).and_return(rows)

    output = with_modified_env(HOURS: '1') { capture_stdout { Rake::Task['medelement:requests:report'].invoke } }
    expect(output).to include('2026102812 11 22 sync_far timetable 429 2 70 15')
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
