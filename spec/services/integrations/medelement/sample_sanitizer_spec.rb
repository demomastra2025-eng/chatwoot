require 'rails_helper'

RSpec.describe Integrations::Medelement::SampleSanitizer do
  subject(:sanitizer) { described_class.new }

  it 'redacts personal and unknown text while retaining shapes, flags, and times' do
    source = {
      'userName' => 'Synthetic Doctor',
      'phone' => '+7 700 111 22 33',
      'iin' => '000000000000',
      'email' => 'fake@example.invalid',
      'comment' => 'Synthetic free text',
      'unknown' => 'Synthetic unknown text',
      'working' => true,
      'isSchedulePublished' => 1,
      'type' => 'primary',
      'start' => '2026-10-07 09:00:00',
      'timetable' => [{ 'working' => false }, nil],
      'accessToken' => 'synthetic_token_value_never_used_123'
    }

    result = sanitizer.sanitize(source)

    expect(result).to include(
      'userName' => '<string:16>', 'phone' => '<string:16>', 'iin' => '<string:12>',
      'email' => '<string:20>', 'comment' => '<string:19>', 'unknown' => '<string:22>',
      'working' => true, 'isSchedulePublished' => 1, 'type' => 'primary',
      'start' => '2026-10-07 09:00:00', 'timetable' => [{ 'working' => false }, nil]
    )
    expect(result).not_to have_key('accessToken')
  end

  it 'replaces cabinet codes with a stable short hash and drops credential fields' do
    source = {
      'cabinets' => [
        { 'companyCabinetCode' => 'CAB-SYNTHETIC-1', 'cabinetName' => 'Room A' },
        { 'companyCabinetCode' => 'CAB-SYNTHETIC-1' }
      ],
      'authorization' => 'synthetic_token_value_never_used_123',
      'integrator_key' => 'synthetic_token_value_never_used_123'
    }

    result = sanitizer.sanitize(source)
    codes = result.fetch('cabinets').map { |cabinet| cabinet.fetch('companyCabinetCode') }

    expect(codes.uniq.size).to eq(1)
    expect(codes.first).to match(/\A<hash:[0-9a-f]{10}>\z/)
    expect(JSON.generate(result)).not_to include('CAB-SYNTHETIC-1', 'Room A', 'synthetic_token')
    expect(result.keys).to eq(['cabinets'])
  end
end
