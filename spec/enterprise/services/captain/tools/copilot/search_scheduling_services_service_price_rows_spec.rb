require 'rails_helper'

# A price row of a service answer is a recorded link, never proof of eligibility: only the active rows of the service's
# own account are listed and each one is labelled as unverified. All data is synthetic.
RSpec.describe Captain::Tools::Copilot::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }

  before { account.enable_features!('scheduling') }

  def create_service(name, **attributes)
    create(:scheduling_service, account: account, name: name, **attributes)
  end

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
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

      payload = search(query: 'УЗИ почек')
      prices = payload['services'].first['prices']

      expect(prices.pluck('id')).to eq([active.id])
      expect(prices.pluck('account_id')).to eq([account.id])
      expect(prices.pluck('service_eligibility_status')).to eq(['price_link_unverified'])
    end

    it 'returns an empty list for a service whose links are all inactive' do
      create(:scheduling_service_price, account: account, service: service_record, resource: resource, active: false)

      expect(search(query: 'УЗИ почек')['services'].first['prices']).to eq([])
    end
  end
end
