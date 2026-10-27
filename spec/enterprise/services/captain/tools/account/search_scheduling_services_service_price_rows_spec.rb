require 'rails_helper'

# A price row of a service answer is a recorded link, never proof of eligibility: only the active rows of the service's
# own account are listed and each one is labelled as unverified. All data is synthetic.
RSpec.describe Captain::Tools::Account::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('scheduling')
    stub_embedder(account, 'почек' => unit_vector(0))
  end

  def create_service(name, **attributes)
    create(:scheduling_service, account: account, name: name, **attributes).tap { |record| index_service(record, vector_at(0, 0.9)) }
  end

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
  end

  def first_service(payload)
    payload['results'].first['services'].first
  end

  describe 'price rows' do
    let(:service_record) { create_service('УЗИ почек') }
    let(:resource) { create(:scheduling_resource, account: account) }

    it 'lists only the active price links of the same account and labels every one as unverified' do
      active = create(:scheduling_service_price, account: account, service: service_record, resource: resource, active: true)
      inactive_resource = create(:scheduling_resource, account: account)
      create(:scheduling_service_price, account: account, service: service_record, resource: inactive_resource, active: false)
      foreign_resource = create(:scheduling_resource, account: account)
      foreign = create(:scheduling_service_price, account: account, service: service_record, resource: foreign_resource, active: true)
      foreign.update_columns(account_id: other_account.id) # rubocop:disable Rails/SkipsModelValidations
      disabled_resource = create(:scheduling_resource, account: account, active: false)
      create(:scheduling_service_price, account: account, service: service_record, resource: disabled_resource, active: true)
      mismatched_resource = create(:scheduling_resource, account: other_account)
      local_resource = create(:scheduling_resource, account: account)
      bad_link = create(:scheduling_service_price, account: account, service: service_record, resource: local_resource, active: true)
      bad_link.update_columns(resource_id: mismatched_resource.id) # rubocop:disable Rails/SkipsModelValidations

      prices = first_service(search(queries: ['почек']))['prices']

      expect(prices.pluck('id')).to eq([active.id])
      expect(prices.pluck('account_id')).to eq([account.id])
      expect(prices.pluck('service_eligibility_status')).to eq(['price_link_unverified'])
    end

    it 'finds the service with its base price and no rows when the account has no links at all' do
      service_record.update!(base_price: 9_000)

      found = first_service(search(queries: ['почек']))

      expect(found).to include('id' => service_record.id, 'base_price' => 9_000, 'prices' => [])
    end

    it 'returns an empty list for a service whose links are all inactive' do
      create(:scheduling_service_price, account: account, service: service_record, resource: resource, active: false)

      expect(first_service(search(queries: ['почек']))['prices']).to eq([])
    end
  end
end
