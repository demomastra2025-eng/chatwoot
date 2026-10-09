require 'rails_helper'
require 'rake'

RSpec.describe Rake::Task do
  before do
    Rails.application.load_tasks unless described_class.task_defined?('onelink:ai_bookings:report')
    described_class['onelink:ai_bookings:report'].reenable
  end

  it 'prints each read-only result row as JSON with supplied scope' do
    report = instance_double(Scheduling::AiBookingReport, call: [{ 'account_id' => 7, 'ai_appointments' => 2 }])
    allow(Scheduling::AiBookingReport).to receive(:new).with(hours: '6', account_id: '7').and_return(report)

    expect { described_class['onelink:ai_bookings:report'].invoke('6', '7') }.to output("{\"account_id\":7,\"ai_appointments\":2}\n").to_stdout
  end
end
