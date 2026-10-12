# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'

RSpec.describe Captain::Evals::RoutingBenchmark::Triage do
  let(:failing) do
    { 'fixture' => '/work/set/ws_net__family_booking_01.yml', 'dialogue' => 'family_booking_01', 'run' => 2, 'turn' => 4,
      'customer' => "запишите\n  дочку   на среду", 'patient_text' => 'Записала вас на среду в 10:00.', 'acting_agent' => 'Запись к врачу',
      'reasons' => %w[wrong_agent false_success_claim],
      'failures' => [
        { 'id' => 'wrong_agent', 'check' => 'wrong_agent', 'severity' => 'important', 'gate' => 'overall', 'detail' => 'acted: nil' },
        { 'id' => 'false_success_claim', 'check' => 'false_success_claim', 'severity' => 'critical', 'gate' => 'b', 'detail' => 'claims book' }
      ],
      'tool_calls' => [{ 'tool' => 'search_available_slots', 'success' => true }], 'expectation' => { 'agent' => 'Запись к врачу' } }
  end

  describe '.records' do
    it 'makes one record per failed check, critical first, with an empty triage field' do
      records = described_class.records([failing])

      expect(records.pluck('check')).to eq(%w[false_success_claim wrong_agent])
      expect(records.first).to eq(
        'fixture' => 'ws_net__family_booking_01.yml', 'dialogue' => 'family_booking_01', 'run' => 2, 'turn' => 4, 'check' => 'false_success_claim',
        'severity' => 'critical', 'gate' => 'b', 'detail' => 'claims book', 'signature' => records.first['signature'],
        'patient_message' => 'запишите дочку на среду',
        'agent_reply' => 'Записала вас на среду в 10:00.', 'acting_agent' => 'Запись к врачу',
        'tool_calls' => [{ 'tool' => 'search_available_slots', 'success' => true }], 'expectation' => { 'agent' => 'Запись к врачу' }, 'triage' => nil
      )
      expect(records.first['signature']).to match(/\A\h{8}\z/)
    end

    it 'sorts by severity, then by fixture, dialogue, run and turn' do
      early = failing.merge('dialogue' => 'a_dialogue', 'turn' => 9, 'failures' => [failing['failures'].first])
      records = described_class.records([early, failing])

      expect(records.map { |record| [record['severity'], record['dialogue'], record['check']] }).to eq(
        [%w[critical family_booking_01 false_success_claim], %w[important a_dialogue wrong_agent], %w[important family_booking_01 wrong_agent]]
      )
    end

    it 'falls back to the reply and to the tool steps of an older report, and reads severities from the table' do
      old = { 'fixture' => 'a.yml', 'dialogue' => 'd', 'turn' => 1, 'customer' => 'x', 'reply' => 'old reply',
              'reasons' => ['forbidden_tool:create_appointment'], 'tool_steps' => ['create_appointment:true:300'] }

      expect(described_class.records([old]).first).to include('severity' => 'critical', 'agent_reply' => 'old reply',
                                                              'tool_calls' => [{ 'tool' => 'create_appointment', 'success' => true }])
    end

    it 'puts a decided label into the record' do
      labels = { described_class.key('ws_net__family_booking_01.yml', 'family_booking_01', 4, 'wrong_agent') => 'judge_error' }

      expect(described_class.records([failing], labels: labels).pluck('triage')).to eq([nil, 'judge_error'])
    end
  end

  describe 'a label belongs to one failure, not to a place in a dialogue' do
    let(:booked) do
      { 'fixture' => '/work/set/ws_mid__kazakh_mixed_01.yml', 'dialogue' => 'kazakh_mixed_01', 'run' => 1, 'turn' => 3,
        'reasons' => ['forbidden_tool:create_appointment'],
        'failures' => [{ 'id' => 'forbidden_tool:create_appointment', 'check' => 'forbidden_tool', 'severity' => 'critical', 'gate' => 'a,c',
                         'detail' => 'create_appointment completed successfully with {"resource_id"=>7, "starts_at"=>"2026-10-15T12:00"}' }],
        'db_delta' => [{ 'id' => 31, 'change' => 'created', 'resource' => 'doctor_a', 'starts_at' => '2026-10-15T12:00:00+05:00' }] }
    end
    let(:failure) { booked['failures'].first }

    def labelled(item, label = 'test_bug')
      earlier = described_class.records([item]).map { |record| record.merge('triage' => label) }
      described_class.labels_from('triage' => earlier)
    end

    it 'carries the label to the same failure in a later run, whatever the row ids of that run' do
      later = booked.merge('run' => 2, 'db_delta' => [booked['db_delta'].first.merge('id' => 977)],
                           'failures' => [failure.merge('detail' => failure['detail'].sub('resource_id"=>7', 'resource_id"=>412'))])

      expect(described_class.records([later], labels: labelled(booked)).pluck('triage')).to eq(['test_bug'])
    end

    it 'does not carry the label to a failure of the same check on the same turn that differs: another doctor is booked' do
      wrong_doctor = booked.merge('db_delta' => [booked['db_delta'].first.merge('resource' => 'doctor_b')])

      expect(described_class.records([wrong_doctor], labels: labelled(booked)).pluck('triage')).to eq([nil])
    end

    it 'does not carry the label when the detail differs' do
      other = booked.merge('failures' => [failure.merge('detail' => 'create_appointment completed successfully with {"starts_at"=>"2026-10-16T09:00"}')])

      expect(described_class.records([other], labels: labelled(booked)).pluck('triage')).to eq([nil])
    end

    it 'lets a label written by hand for the check on that turn (no signature) cover every failure of it' do
      by_hand = { described_class.key('ws_mid__kazakh_mixed_01.yml', 'kazakh_mixed_01', 3, 'forbidden_tool:create_appointment') => 'agent_bug' }
      wrong_doctor = booked.merge('db_delta' => [booked['db_delta'].first.merge('resource' => 'doctor_b')])

      expect(described_class.records([booked, wrong_doctor], labels: by_hand).pluck('triage')).to eq(%w[agent_bug agent_bug])
    end

    it 'leaves record ids out of the signature, but not times' do
      expect(described_class.signature(booked, failure)).to eq(described_class.signature(booked.merge('db_delta' => [booked['db_delta'].first.merge('id' => 5)]), failure))
      later_time = booked.merge('db_delta' => [booked['db_delta'].first.merge('starts_at' => '2026-10-15T13:00:00+05:00')])

      expect(described_class.signature(later_time, failure)).not_to eq(described_class.signature(booked, failure))
    end
  end

  describe '.load' do
    def with_file(content)
      Tempfile.create(['triage', '.json']) do |file|
        file.write(content.to_json)
        file.flush
        yield file.path
      end
    end

    it 'reads the labels from the triage records of an earlier report, ignoring empty and unknown labels' do
      records = described_class.records([failing]).each_with_index.map { |record, index| record.merge('triage' => %w[agent_bug bogus][index]) }

      with_file('triage' => records) do |path|
        expect(described_class.load(path)).to eq(described_class.key('ws_net__family_booking_01.yml', 'family_booking_01', 4,
                                                                     'false_success_claim', records.first['signature']) => 'agent_bug')
      end
    end

    it 'keys a record without a signature (an older report) by the check on the turn' do
      record = described_class.records([failing]).first.except('signature').merge('triage' => 'test_bug')

      with_file([record]) do |path|
        expect(described_class.load(path)).to eq('ws_net__family_booking_01.yml|family_booking_01|4|false_success_claim' => 'test_bug')
      end
    end

    it 'reads a plain list of records and a labels object' do
      record = described_class.records([failing]).first.merge('triage' => 'test_bug')

      with_file([record]) { |path| expect(described_class.load(path).values).to eq(['test_bug']) }
      with_file('labels' => { 'k' => 'agent_bug' }) { |path| expect(described_class.load(path)).to eq('k' => 'agent_bug') }
    end

    it 'is empty without a path' do
      expect(described_class.load(nil)).to eq({})
      expect(described_class.load('')).to eq({})
    end
  end

  it 'identifies a failure by fixture file name, dialogue, turn and check, whatever the run' do
    expect(described_class.key('/a/b/ws.yml', 'd', 2, 'wrong_agent')).to eq('ws.yml|d|2|wrong_agent')
  end
end
