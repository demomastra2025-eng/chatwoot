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

  it 'preserves non-conflicting specialist prices and audibly quarantines conflicts', :aggregate_failures do
    account = create(:account)
    code_attributes = { 'medelement_nomenclature_code' => test_code }
    keeper = create(:scheduling_service, account: account, custom_attributes: code_attributes)
    duplicate = create(:scheduling_service, account: account, custom_attributes: code_attributes)
    resources = create_list(:scheduling_resource, 4, account: account)
    create(:scheduling_service_price, account: account, service: keeper, resource: resources[0])
    create(:scheduling_service_price, account: account, service: keeper, resource: resources[1])
    create(:scheduling_service_price, account: account, service: keeper, resource: resources[3])
    migrated_price = create(:scheduling_service_price, account: account, service: duplicate, resource: resources[2])
    conflicting_price = create(:scheduling_service_price, account: account, service: duplicate, resource: resources[0])

    migration.up

    expect(keeper.reload.custom_attributes['medelement_nomenclature_code']).to eq(test_code)
    expect(duplicate.reload).not_to be_active
    expect(duplicate.custom_attributes).to include(
      'medelement_duplicate_nomenclature_code' => test_code,
      'medelement_duplicate_of_service_id' => keeper.id,
      'medelement_duplicate_was_active' => true,
      'medelement_migrated_price_ids' => [migrated_price.id],
      'medelement_deactivated_price_ids' => [conflicting_price.id]
    )
    expect(duplicate.custom_attributes).not_to have_key('medelement_nomenclature_code')
    expect(migrated_price.reload).to have_attributes(service_id: keeper.id, active: true)
    expect(conflicting_price.reload).to have_attributes(service_id: duplicate.id, active: false)
    expect(connection.index_name_exists?(:scheduling_services, described_class::INDEX_NAME)).to be(true)

    migration.down

    expect(migrated_price.reload).to have_attributes(service_id: duplicate.id, active: true)
    expect(conflicting_price.reload).to have_attributes(service_id: duplicate.id, active: true)
    expect(duplicate.reload).to be_active
    expect(duplicate.custom_attributes).to include('medelement_nomenclature_code' => test_code)
    expect(duplicate.custom_attributes.keys).not_to include(
      'medelement_duplicate_nomenclature_code',
      'medelement_duplicate_of_service_id',
      'medelement_duplicate_was_active',
      'medelement_migrated_price_ids',
      'medelement_deactivated_price_ids'
    )
    expect(connection.index_name_exists?(:scheduling_services, described_class::INDEX_NAME)).to be(false)
  end

  it 'does not deduplicate services whose provider code is blank' do
    account = create(:account)
    blank_code = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => '' }
    )
    whitespace_code = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => '   ' }
    )

    migration.up

    expect(blank_code.reload).to be_active
    expect(whitespace_code.reload).to be_active
    expect(blank_code.custom_attributes['medelement_nomenclature_code']).to eq('')
    expect(whitespace_code.custom_attributes['medelement_nomenclature_code']).to eq('   ')
  end
end
