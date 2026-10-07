require 'rails_helper'
require 'tmpdir'

RSpec.describe Integrations::Medelement::SampleCapture do
  let(:hook) { instance_double(Integrations::Hook, app_id: 'medelement', enabled?: false) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:today) { Date.new(2026, 10, 7) }
  let(:doctors) do
    [
      { 'specialistCode' => 'S-1', 'isSchedulePublished' => 1, 'userName' => 'Synthetic One' },
      { 'specialistCode' => 'S-2', 'isSchedulePublished' => 0, 'userName' => 'Synthetic Two' },
      { 'specialistCode' => 'S-3', 'isSchedulePublished' => 1,
        'cabinets' => [{ 'companyCabinetCode' => 'C-1' }, { 'companyCabinetCode' => 'C-2' }] },
      { 'specialistCode' => 'S-4', 'isSchedulePublished' => 1 }
    ]
  end

  def capture_in(directory, **)
    described_class.new(hook: hook, client: client, today: today, output_root: Pathname.new(directory), **)
  end

  it 'chooses published, unpublished, and multi-cabinet doctors within the limit' do
    capture = capture_in('/tmp', max_doctors: 3)

    expect(capture.select_doctors(doctors).map { |doctor| doctor['specialistCode'] }).to eq(%w[S-1 S-2 S-3])
  end

  it 'caps requests and never calls another client method' do
    Dir.mktmpdir do |directory|
      allow(client).to receive(:specialists).and_return(doctors)
      allow(client).to receive(:timetable).and_return({ '04.10.2026' => { 'timetable' => [] } })
      capture = capture_in(directory, max_requests: 2)

      capture.perform

      expect(client).to have_received(:specialists).once
      expect(client).to have_received(:timetable).once
      expect(JSON.parse(File.read(Dir.glob("#{directory}/*/samples.json").first)).size).to eq(2)
    end
  end

  it 'refuses an enabled hook without confirmation and production without its override' do
    allow(hook).to receive(:enabled?).and_return(true)
    expect(client).not_to receive(:specialists)

    expect { capture_in('/tmp', confirm: nil).perform }.to raise_error(described_class::Refused)
    expect { capture_in('/tmp', confirm: '1', production: true, allow_production: nil).perform }
      .to raise_error(described_class::Refused)
  end

  it 'writes sanitized samples and a Russian shape summary without secret-like values' do
    Dir.mktmpdir do |directory|
      allow(client).to receive(:specialists).and_return(
        [{ 'specialistCode' => 'S-1', 'isSchedulePublished' => false,
           'userName' => 'Synthetic Doctor', 'apiKey' => 'synthetic_token_value_never_used_123' }]
      )
      allow(client).to receive(:timetable).and_return(
        { '04.10.2026' => { 'timetable' => [
          { 'working' => true, 'start' => '09:00', 'end' => '10:00',
            'phone' => '+7 700 111 22 33', 'companyCabinetCode' => 'C-1' }
        ] } }
      )
      capture = capture_in(directory, max_requests: 2)

      output = capture.perform
      samples = File.read(output.join('samples.json'))
      shapes = File.read(output.join('SHAPES.md'))

      expect(samples).not_to include('Synthetic Doctor', 'synthetic_token_value', '+7 700', 'C-1')
      expect(shapes).to include('Поля врача', 'Поля строки расписания', '2026-10-04', 'опубликован=false')
      expect(shapes).to include('объект с ключами дат dd.MM.yyyy')
      expect(shapes).to include('specialistWorkingHours="day off"', 'date[0]', 'by_update_date')
      expect(capture.summary.size).to eq(10)
    end
  end

  it 'stops after three consecutive request failures' do
    Dir.mktmpdir do |directory|
      allow(client).to receive(:specialists).and_return(doctors)
      allow(client).to receive(:timetable).and_raise(
        Integrations::Medelement::Client::ApiError.new('Synthetic failure', status: 503)
      )
      capture = capture_in(directory)

      output = capture.perform
      records = JSON.parse(File.read(output.join('samples.json')))

      expect(client).to have_received(:timetable).exactly(3).times
      expect(records.last.fetch('status_class')).to eq('5xx')
      expect(File.read(output.join('SHAPES.md'))).not_to include('Synthetic failure')
    end
  end
end
