require 'rails_helper'

RSpec.describe Scheduling::VisitDuration do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account, slot_duration_min: 15) }
  let(:local_service) { create(:scheduling_service, account: account, duration_min: 45) }
  # duration_min 30 is the column default of every imported MedElement service, not a real length
  let(:provider_service) do
    create(:scheduling_service, account: account, duration_min: 30, custom_attributes: { 'medelement_nomenclature_code' => 'U1' })
  end

  def minutes(**)
    described_class.minutes(resource: resource, service: provider_service, **)
  end

  def record_pair(status: 'auto', median: 15, **attributes)
    create(:scheduling_resource_service_stat, account: account, resource: resource, service: provider_service,
                                              status: status, median_duration_min: median, **attributes)
  end

  it 'uses the requested length first' do
    record_pair(median: 15)

    expect(minutes(requested: 50)).to eq(50)
    expect(described_class.minutes(resource: resource, service: local_service, requested: '20')).to eq(20)
    expect(described_class.minutes(resource: resource, service: nil, requested: 25)).to eq(25)
  end

  it 'ignores a zero or negative request' do
    expect(described_class.minutes(resource: resource, service: local_service, requested: 0)).to eq(45)
    expect(described_class.minutes(resource: resource, service: nil, requested: -5)).to eq(15)
  end

  it 'uses the slot of the specialist when there is no service' do
    expect(described_class.minutes(resource: resource, service: nil)).to eq(15)
  end

  it 'keeps the own length of a local service' do
    record_pair(median: 10)
    create(:scheduling_resource_service_stat, account: account, resource: resource, service: local_service, median_duration_min: 10)

    expect(described_class.minutes(resource: resource, service: local_service)).to eq(45)
  end

  describe 'a MedElement service' do
    it 'uses the median length of the pair when it fits the slot' do
      record_pair(median: 15)

      expect(minutes).to eq(15)
    end

    it 'rounds the median up to the slot of the specialist' do
      record_pair(median: 10)
      expect(minutes).to eq(15)

      resource.update!(slot_duration_min: 30)
      expect(minutes).to eq(30)
    end

    it 'rounds the median up to a whole number of slots' do
      record_pair(median: 40)

      expect(minutes).to eq(45)
    end

    it 'never exceeds the longest visit the calendar accepts' do
      resource.update!(slot_duration_min: 7)
      record_pair(median: Scheduling::Constants::MAX_DURATION_MINUTES)

      expect(minutes).to eq(Scheduling::Constants::MAX_DURATION_MINUTES)
    end

    it 'uses the slot of the specialist, never the 30 minutes default, when the pair is unknown' do
      expect(minutes).to eq(15)
    end

    it 'uses the slot when the pair has no median' do
      record_pair(median: nil)

      expect(minutes).to eq(15)
    end

    it 'uses a confirmed pair and ignores a disabled or a stale one' do
      pair = record_pair(status: 'confirmed', median: 30)
      expect(minutes).to eq(30)

      pair.update!(status: 'disabled')
      expect(minutes).to eq(15)

      pair.update!(status: 'stale')
      expect(minutes).to eq(15)
    end

    it 'uses the pair of its own specialist and its own service only' do
      other_resource = create(:scheduling_resource, account: account, slot_duration_min: 15)
      create(:scheduling_resource_service_stat, account: account, resource: other_resource, service: provider_service, median_duration_min: 60)
      create(:scheduling_resource_service_stat, account: account, resource: resource, median_duration_min: 60)

      expect(minutes).to eq(15)
    end

    it 'reads the pairs given by stats without a query' do
      stat = build_stubbed(:scheduling_resource_service_stat, resource: resource, service: provider_service, median_duration_min: 30)

      expect(Scheduling::ResourceServiceStat).not_to receive(:usable)
      expect(minutes(stats: { resource.id => stat })).to eq(30)
      expect(minutes(stats: {})).to eq(15)
    end
  end

  describe '.stats_for' do
    it 'loads the usable pairs of a MedElement service by specialist in one query' do
      other_resource = create(:scheduling_resource, account: account)
      kept = record_pair(median: 20)
      create(:scheduling_resource_service_stat, account: account, resource: other_resource, service: provider_service, status: 'disabled')

      stats = described_class.stats_for(service: provider_service, resource_ids: [resource.id, other_resource.id])

      expect(stats).to eq(resource.id => kept)
    end

    it 'loads nothing for a local service or without specialists' do
      create(:scheduling_resource_service_stat, account: account, resource: resource, service: local_service)

      expect(described_class.stats_for(service: local_service, resource_ids: [resource.id])).to eq({})
      expect(described_class.stats_for(service: nil, resource_ids: [resource.id])).to eq({})
      expect(described_class.stats_for(service: provider_service, resource_ids: [])).to eq({})
    end
  end

  describe '.service_payload' do
    it 'shows the length of the visit instead of the default of a MedElement service' do
      expect(described_class.service_payload(provider_service, duration_min: 15)).to include(id: provider_service.id, duration_min: 15)
      expect(described_class.service_payload(provider_service, duration_min: nil)).not_to have_key(:duration_min)
    end

    it 'leaves a local service as it is' do
      expect(described_class.service_payload(local_service, duration_min: 15)).to include(duration_min: 45)
    end
  end
end
