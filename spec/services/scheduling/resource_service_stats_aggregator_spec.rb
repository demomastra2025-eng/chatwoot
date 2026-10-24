require 'rails_helper'

RSpec.describe Scheduling::ResourceServiceStatsAggregator do
  let(:account) { create(:account) }
  let(:doctor_a) { create(:scheduling_resource, account: account, name: 'Doctor A', slot_duration_min: 15) }
  let(:doctor_b) { create(:scheduling_resource, account: account, name: 'Doctor B', slot_duration_min: 15) }
  let(:codes_key) { 'medelement_provider_nomenclature_codes' }

  def service_with_code(code, **attributes)
    create(:scheduling_service, account: account, custom_attributes: { 'medelement_nomenclature_code' => code }, **attributes)
  end

  # Imported receptions carry the service codes after the visit. One visit per length in `minutes`, or `count` visits of one length.
  # Options: minutes (a length, or an array with one length per visit), count, status, days_ago, owner (the account of the visits).
  def record_visits(resource, codes, **options)
    minutes = options.fetch(:minutes, 15)
    lengths = minutes.is_a?(Array) ? minutes : Array.new(options.fetch(:count, 1), minutes)
    rows = lengths.each_with_index.map do |length, index|
      starts_at = options.fetch(:days_ago, 10).days.ago.beginning_of_day + 8.hours + (index * 30).minutes
      { account_id: options.fetch(:owner, account).id, resource_id: resource.id, client_name: 'Patient',
        status: options.fetch(:status, 'completed'), source: 'medelement',
        starts_at: starts_at, ends_at: starts_at + length.minutes, duration_min: length,
        custom_attributes: { codes_key => Array(codes) } }
    end
    Scheduling::Appointment.insert_all!(rows) # rubocop:disable Rails/SkipsModelValidations
  end

  def aggregate(dry_run: false, **)
    described_class.new(account: account, **).perform(dry_run: dry_run)
  end

  def stat_for(resource, service)
    Scheduling::ResourceServiceStat.find_by(resource_id: resource.id, service_id: service.id)
  end

  describe 'thresholds' do
    it 'counts a pair with at least 3 visits and at least 5 percent of the visits of its service' do
      service = service_with_code('S1')
      record_visits(doctor_a, 'S1', count: 3)
      record_visits(doctor_b, 'S1', count: 57)

      result = aggregate

      expect(result).to have_attributes(history_pairs: 2, counted_pairs: 2, created: 2)
      expect(stat_for(doctor_a, service)).to have_attributes(receptions_count: 3, status: 'auto', source: 'history')
      expect(stat_for(doctor_b, service)).to have_attributes(receptions_count: 57, status: 'auto')
    end

    it 'drops a pair with fewer than 3 visits' do
      service = service_with_code('S2')
      record_visits(doctor_a, 'S2', count: 2)
      record_visits(doctor_b, 'S2', count: 10)

      aggregate

      expect(stat_for(doctor_a, service)).to be_nil
      expect(stat_for(doctor_b, service)).to be_present
    end

    it 'drops a pair below 5 percent of the visits of its service' do
      service = service_with_code('S3')
      record_visits(doctor_a, 'S3', count: 3)
      record_visits(doctor_b, 'S3', count: 60)

      aggregate

      expect(stat_for(doctor_a, service)).to be_nil
      expect(stat_for(doctor_b, service)).to have_attributes(receptions_count: 60, status: 'auto')
    end

    it 'counts a code once per visit and ignores a code that no service has' do
      service = service_with_code('S4')
      record_visits(doctor_a, %w[S4 S4 UNKNOWN], count: 3)

      aggregate

      expect(Scheduling::ResourceServiceStat.count).to eq(1)
      expect(stat_for(doctor_a, service).receptions_count).to eq(3)
    end
  end

  describe 'which visits are read' do
    it 'ignores cancelled and no-show visits, visits older than 180 days and visits that have not happened yet' do
      service = service_with_code('V1')
      record_visits(doctor_a, 'V1', minutes: [20, 20, 20])
      record_visits(doctor_a, 'V1', count: 5, status: 'cancelled', minutes: 90)
      record_visits(doctor_a, 'V1', count: 5, status: 'no_show', minutes: 90)
      record_visits(doctor_a, 'V1', count: 5, days_ago: 200, minutes: 90)
      record_visits(doctor_a, 'V1', count: 5, days_ago: -3, minutes: 90)

      aggregate

      expect(stat_for(doctor_a, service)).to have_attributes(receptions_count: 3, median_duration_min: 20)
    end

    it 'counts a past visit whose status has not caught up with the provider yet' do
      service = service_with_code('V2')
      %w[completed scheduled confirmed].each { |status| record_visits(doctor_a, 'V2', status: status) }

      aggregate

      expect(stat_for(doctor_a, service)).to have_attributes(receptions_count: 3, status: 'auto')
    end

    it 'reads only the visits and the services of the account' do
      other_account = create(:account)
      other_doctor = create(:scheduling_resource, account: other_account)
      service = service_with_code('V3')
      create(:scheduling_service, account: other_account, custom_attributes: { 'medelement_nomenclature_code' => 'V3' })
      record_visits(doctor_a, 'V3', count: 3)
      record_visits(other_doctor, 'V3', count: 40, owner: other_account)

      aggregate

      expect(Scheduling::ResourceServiceStat.pluck(:account_id, :resource_id, :service_id, :receptions_count))
        .to eq([[account.id, doctor_a.id, service.id, 3]])
    end

    it 'reads the window given by window_days' do
      service = service_with_code('V4')
      record_visits(doctor_a, 'V4', count: 3, days_ago: 40)

      aggregate(window_days: 30)
      expect(stat_for(doctor_a, service)).to be_nil

      aggregate(window_days: 60)
      expect(stat_for(doctor_a, service)).to be_present
    end
  end

  describe 'payment lines and laboratory tests' do
    it 'drops prepayment, payment and deposit lines' do
      ['Предоплата 5000', 'предоплата УЗИ', 'Оплата услуг', 'Депозит пациента'].each_with_index do |name, index|
        service_with_code("P#{index}", name: name)
        record_visits(doctor_a, "P#{index}", count: 5)
      end
      kept = service_with_code('P9', name: 'УЗИ малого таза')
      record_visits(doctor_a, 'P9', count: 5)

      result = aggregate

      expect(result.history_pairs).to eq(1)
      expect(Scheduling::ResourceServiceStat.pluck(:service_id)).to eq([kept.id])
    end

    it 'drops laboratory categories and keeps a category that only contains the letters' do
      service_with_code('L1', name: 'Глюкоза', category: 'ЛИС КДЛ Биохимия')
      service_with_code('L2', name: 'Общий анализ крови', category: 'Лабораторная диагностика')
      service_with_code('L3', name: 'Гемоглобин', direction: 'Лаборатория')
      kept = service_with_code('L4', name: 'Полисомнография', category: 'Полисомнография')
      %w[L1 L2 L3 L4].each { |code| record_visits(doctor_a, code, count: 5) }

      aggregate

      expect(Scheduling::ResourceServiceStat.pluck(:service_id)).to eq([kept.id])
    end

    it 'tells a noise service by the same rule outside the aggregation' do
      expect(described_class.noise_service?(build(:scheduling_service, name: 'Предоплата 5000'))).to be(true)
      expect(described_class.noise_service?(build(:scheduling_service, category: 'ЛИС КДЛ'))).to be(true)
      expect(described_class.noise_service?(build(:scheduling_service, name: 'Консультация', category: 'Терапия'))).to be(false)
    end
  end

  describe 'the median length of a visit' do
    it 'is the middle length of the visits of the pair' do
      service = service_with_code('M1')
      record_visits(doctor_a, 'M1', minutes: [10, 15, 15, 20, 60])
      record_visits(doctor_b, 'M1', minutes: [30, 30, 30])

      aggregate

      expect(stat_for(doctor_a, service).median_duration_min).to eq(15)
      expect(stat_for(doctor_b, service).median_duration_min).to eq(30)
    end

    it 'rounds the middle of two lengths up to whole minutes' do
      service = service_with_code('M2')
      record_visits(doctor_a, 'M2', minutes: [10, 15, 20, 25])

      aggregate

      expect(stat_for(doctor_a, service).median_duration_min).to eq(18)
    end

    it 'keeps the time of the last visit' do
      service = service_with_code('M3')
      record_visits(doctor_a, 'M3', count: 2, days_ago: 30)
      record_visits(doctor_a, 'M3', count: 1, days_ago: 4)

      aggregate

      expect(stat_for(doctor_a, service).last_seen_at).to be_within(1.minute).of(4.days.ago.beginning_of_day + 8.hours)
    end
  end

  describe 'rows that already exist' do
    let!(:service) { service_with_code('R1') }

    it 'keeps a confirmed row confirmed when the pair no longer counts, and refreshes its numbers' do
      create(:scheduling_resource_service_stat, account: account, resource: doctor_a, service: service, status: 'confirmed',
                                                receptions_count: 99, median_duration_min: 40)
      record_visits(doctor_a, 'R1', minutes: [20])

      result = aggregate

      expect(stat_for(doctor_a, service)).to have_attributes(status: 'confirmed', receptions_count: 1, median_duration_min: 20)
      expect(result).to have_attributes(created: 0, updated: 1, staled: 0)
    end

    it 'keeps a disabled row disabled when the pair counts' do
      create(:scheduling_resource_service_stat, account: account, resource: doctor_a, service: service, status: 'disabled',
                                                receptions_count: 0, median_duration_min: nil)
      record_visits(doctor_a, 'R1', count: 5, minutes: 20)

      aggregate

      expect(stat_for(doctor_a, service)).to have_attributes(status: 'disabled', receptions_count: 5, median_duration_min: 20)
    end

    it 'turns an auto row that falls below the thresholds into stale and never deletes it' do
      create(:scheduling_resource_service_stat, account: account, resource: doctor_a, service: service, status: 'auto', receptions_count: 8)
      record_visits(doctor_a, 'R1', count: 2, minutes: 25)

      result = aggregate

      expect(stat_for(doctor_a, service)).to have_attributes(status: 'stale', receptions_count: 2, median_duration_min: 25)
      expect(result).to have_attributes(staled: 1, updated: 0)
      expect(Scheduling::ResourceServiceStat.count).to eq(1)
    end

    it 'turns an auto row that vanished from the history into stale with no visits, keeping the last known numbers' do
      last_seen = 40.days.ago.change(usec: 0)
      create(:scheduling_resource_service_stat, account: account, resource: doctor_a, service: service, status: 'auto',
                                                receptions_count: 8, median_duration_min: 25, last_seen_at: last_seen)

      aggregate

      expect(stat_for(doctor_a, service)).to have_attributes(status: 'stale', receptions_count: 0, median_duration_min: 25,
                                                             last_seen_at: last_seen)
    end

    it 'turns a stale row into auto when the pair counts again' do
      create(:scheduling_resource_service_stat, account: account, resource: doctor_a, service: service, status: 'stale', receptions_count: 0)
      record_visits(doctor_a, 'R1', count: 4)

      aggregate

      expect(stat_for(doctor_a, service)).to have_attributes(status: 'auto', receptions_count: 4)
    end

    it 'changes nothing on a second run' do
      record_visits(doctor_a, 'R1', count: 4)
      aggregate
      stamp = stat_for(doctor_a, service).updated_at

      result = aggregate

      expect(result).to have_attributes(created: 0, updated: 0, staled: 0, unchanged: 1)
      expect(stat_for(doctor_a, service).updated_at).to eq(stamp)
    end

    it 'keeps a status that staff set while the run was reading' do
      row = create(:scheduling_resource_service_stat, account: account, resource: doctor_a, service: service, status: 'auto',
                                                      receptions_count: 8)
      record_visits(doctor_a, 'R1', count: 2)
      aggregator = described_class.new(account: account)
      aggregator.send(:existing_rows)
      row.update_columns(status: 'confirmed') # rubocop:disable Rails/SkipsModelValidations

      aggregator.perform

      expect(row.reload).to have_attributes(status: 'confirmed', receptions_count: 2)
    end
  end

  describe 'a dry run' do
    it 'reports what a run would do and writes nothing' do
      service_with_code('D1')
      record_visits(doctor_a, 'D1', count: 5)

      result = aggregate(dry_run: true)

      expect(result).to have_attributes(dry_run: true, history_pairs: 1, counted_pairs: 1, created: 1)
      expect(Scheduling::ResourceServiceStat.count).to eq(0)
    end
  end
end
