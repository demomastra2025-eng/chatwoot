require 'rails_helper'

# A service asks for a new vector only when the text it is embedded as (name, aliases, category) changes. The MedElement catalog sync
# saves every service on every run and changes only its last-seen mark: it must cost no embedding.
RSpec.describe Scheduling::Service, '#refresh_embedding_later' do
  let(:account) { create(:account) }
  let(:queued_key) { Scheduling::ServiceEmbeddingJob.queued_key(account.id) }

  before { Redis::Alfred.delete(queued_key) }

  def indexed_service(**attributes)
    create(:scheduling_service, account: account, **attributes).tap do |service|
      index_service(service, unit_vector(0))
      Redis::Alfred.delete(queued_key)
    end
  end

  def reindex(service)
    index_service(service, unit_vector(0))
    Redis::Alfred.delete(queued_key)
  end

  it 'queues the refresh of the account when a service is created' do
    expect { create(:scheduling_service, account: account) }.to have_enqueued_job(Scheduling::ServiceEmbeddingJob).with(account.id)
  end

  it 'queues one job for a burst of saves' do
    expect { Array.new(5) { create(:scheduling_service, account: account) } }.to have_enqueued_job(Scheduling::ServiceEmbeddingJob).once
  end

  it 'queues nothing when a save leaves the embedded text as it is' do
    service = indexed_service(custom_attributes: { 'medelement_nomenclature_code' => 'A1', 'medelement_last_seen_at' => '2026-10-26T01:00:00Z' })

    expect do
      service.update!(custom_attributes: service.custom_attributes.merge('medelement_last_seen_at' => '2026-10-27T01:00:00Z'), base_price: 99,
                      description: 'Другое описание', active: false)
    end.not_to have_enqueued_job(Scheduling::ServiceEmbeddingJob)
  end

  it 'costs no embedding to run the MedElement services sync again: one job for the first import, none for the repeat' do
    payloads = Array.new(40) do |index|
      { 'serviceCode' => "ME-#{index}", 'name' => "Услуга номер #{index}", 'basePrice' => 1000, 'category' => 'Диагностика', 'active' => true }
    end
    sync = -> { Integrations::Medelement::ServicesSyncService.new(account: account, client: nil, service_payloads: payloads).perform }

    expect { sync.call }.to have_enqueued_job(Scheduling::ServiceEmbeddingJob).with(account.id).once
    described_class.where(account_id: account.id).find_each { |service| index_service(service, unit_vector(0)) }
    Redis::Alfred.delete(queued_key)

    expect { sync.call }.not_to have_enqueued_job(Scheduling::ServiceEmbeddingJob)
    expect(described_class.where(account_id: account.id).count).to eq(40)
  end

  it 'queues the refresh when the name, the aliases or the category change' do
    service = indexed_service(name: 'УЗИ почек')

    expect { service.update!(name: 'УЗИ почек и надпочечников') }.to have_enqueued_job(Scheduling::ServiceEmbeddingJob)
    reindex(service)
    expect { service.update!(custom_attributes: { 'aliases' => ['почки'] }) }.to have_enqueued_job(Scheduling::ServiceEmbeddingJob)
    reindex(service)
    expect { service.update!(category: 'Диагностика') }.to have_enqueued_job(Scheduling::ServiceEmbeddingJob)
  end

  it 'takes the old vector out of the search at once when the text changes, and keeps it when the text stays' do
    service = indexed_service(name: 'УЗИ почек')

    service.update!(base_price: 5)
    expect(service.reload.embedded_at).to be_present

    service.update!(name: 'УЗИ почек и надпочечников')
    expect(service.reload.embedded_at).to be_nil
  end

  it 'compares with the checksum in the database, not with a copy of the service that was read before the vector was stored' do
    service = create(:scheduling_service, account: account, name: 'УЗИ почек')
    copy = described_class.find(service.id)
    index_service(service, unit_vector(0))
    Redis::Alfred.delete(queued_key)

    expect { copy.update!(base_price: 7) }.not_to have_enqueued_job(Scheduling::ServiceEmbeddingJob)
    expect(service.reload.embedded_at).to be_present
  end

  it 'does not break the save when the queue is not reachable' do
    allow(Scheduling::ServiceEmbeddingJob).to receive(:enqueue).and_raise(RuntimeError, 'redis is down')

    expect { create(:scheduling_service, account: account) }.not_to raise_error
  end

  it 'does not carry the vector in a service that is read: it is searched by SQL only' do
    service = indexed_service

    expect(described_class.find(service.id).attributes.keys).not_to include('embedding')
    expect(described_class.column_names).not_to include('embedding')
  end
end
