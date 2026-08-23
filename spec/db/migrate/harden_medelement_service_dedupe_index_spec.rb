require 'rails_helper'
require Rails.root.join('db/migrate/20260823130000_harden_medelement_service_dedupe_index')

RSpec.describe HardenMedelementServiceDedupeIndex do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    migration.up
    example.run
  ensure
    migration.up
  end

  it 'replaces the legacy predicate and ignores blank provider codes' do
    migration.down

    expect(index_predicate).not_to include('NULLIF')

    migration.up

    expect(index_predicate).to include('NULLIF')
    expect(index_predicate).to include('BTRIM')
  end

  it 'is idempotent when the hardened index already exists' do
    expect { migration.up }.not_to(change { index_predicate })
  end

  def index_predicate
    connection.indexes(:scheduling_services)
              .find { |index| index.name == described_class::INDEX_NAME }
              .where
              .to_s
              .upcase
  end
end
