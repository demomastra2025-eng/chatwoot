require 'rails_helper'

RSpec.describe Scheduling::ResourceSearchService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let!(:therapist) { create(:scheduling_resource, account: account, name: 'Aigerim Sarsembayeva', specialty: 'Therapist') }
  let!(:cosmetologist) { create(:scheduling_resource, account: account, name: 'Dana Nur', specialty: 'Cosmetologist') }
  let!(:inactive_resource) { create(:scheduling_resource, account: account, name: 'Old Therapist', specialty: 'Therapist', active: false) }
  let!(:deleted_resource) do
    create(
      :scheduling_resource,
      account: account,
      name: 'Deleted Specialist',
      custom_attributes: { Scheduling::Resource::DELETED_FROM_SCHEDULING_KEY => true }
    )
  end
  let!(:other_account_resource) { create(:scheduling_resource, account: other_account, name: 'Aigerim Other') }

  def perform(**attributes)
    described_class.new(account: account, **attributes).perform
  end

  it 'lists only active non-deleted specialists from the current account by default' do
    payload = perform

    expect(payload[:total_count]).to eq(2)
    expect(payload[:resources].pluck(:id)).to contain_exactly(therapist.id, cosmetologist.id)
    expect(payload[:resources].pluck(:id)).not_to include(inactive_resource.id, deleted_resource.id, other_account_resource.id)
  end

  it 'searches by name, specialty, or both without leaking inactive specialists by default' do
    expect(perform(query: 'aigerim', search_by: 'name')[:resources].pluck(:id)).to eq([therapist.id])
    expect(perform(query: 'cosmet', search_by: 'specialty')[:resources].pluck(:id)).to eq([cosmetologist.id])
    expect(perform(query: 'therapist', search_by: 'all')[:resources].pluck(:id)).to eq([therapist.id])
  end

  it 'can include inactive specialists when explicitly requested' do
    payload = perform(query: 'old', include_inactive: true)

    expect(payload[:resources].pluck(:id)).to eq([inactive_resource.id])
  end

  it 'filters specialists by active service price and keeps results distinct' do
    service = create(:scheduling_service, account: account, name: 'Consultation')
    create(:scheduling_service_price, account: account, service: service, resource: therapist, active: true)
    create(:scheduling_service_price, account: account, service: service, resource: cosmetologist, active: false)

    payload = perform(service_id: service.id)

    expect(payload[:total_count]).to eq(1)
    expect(payload[:resources].pluck(:id)).to eq([therapist.id])
  end

  it 'caps result limits to protect the agent from unbounded payloads' do
    create_list(:scheduling_resource, 55, account: account)

    payload = perform(limit: 500)

    expect(payload[:total_count]).to eq(57)
    expect(payload[:resources].length).to eq(described_class::MAX_LIMIT)
  end
end
