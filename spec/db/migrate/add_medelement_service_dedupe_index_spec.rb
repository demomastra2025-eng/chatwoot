require 'rails_helper'
require Rails.root.join('db/migrate/20260728110000_add_medelement_service_dedupe_index')

RSpec.describe AddMedelementServiceDedupeIndex do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:test_code) { 'ME-SVC-DUPLICATE' }

  around do |example|
    migration.down if connection.index_name_exists?(:scheduling_services, described_class::INDEX_NAME)
    example.run
  ensure
    migration.up unless connection.index_name_exists?(:scheduling_services, described_class::INDEX_NAME)
  end

  it 'soft-quarantines existing duplicates before creating the unique index' do
    account = create(:account)
    code_attributes = { 'medelement_nomenclature_code' => test_code }
    keeper = create(:scheduling_service, account: account, custom_attributes: code_attributes)
    duplicate = create(:scheduling_service, account: account, custom_attributes: code_attributes)
    resources = create_list(:scheduling_resource, 3, account: account)
    create(:scheduling_service_price, account: account, service: keeper, resource: resources[0])
    create(:scheduling_service_price, account: account, service: keeper, resource: resources[1])
    duplicate_price = create(:scheduling_service_price, account: account, service: duplicate, resource: resources[2])

    migration.up

    expect(keeper.reload.custom_attributes['medelement_nomenclature_code']).to eq(test_code)
    expect(duplicate.reload).not_to be_active
    expect(duplicate.custom_attributes).to include(
      'medelement_duplicate_nomenclature_code' => test_code,
      'medelement_duplicate_of_service_id' => keeper.id
    )
    expect(duplicate.custom_attributes).not_to have_key('medelement_nomenclature_code')
    expect(duplicate_price.reload).not_to be_active
    expect(connection.index_name_exists?(:scheduling_services, described_class::INDEX_NAME)).to be(true)
  end
end
