# frozen_string_literal: true

# Maps the keys of a fixture workspace (resource, service, contact) to the records created for it, and back. A fixture
# expectation names a doctor or a patient by key; the scorer compares the rows of the isolated database with it. The
# workspace text (knowledge base, doctor, service and contact names) is what a reply may repeat without leaking.
class Captain::Evals::RoutingBenchmark::Directory
  attr_reader :texts

  def initialize(resources: {}, services: {}, contacts: {}, texts: [])
    @resources = resources.transform_keys(&:to_s)
    @services = services.transform_keys(&:to_s)
    @contacts = contacts.transform_keys(&:to_s)
    @texts = texts.compact.map(&:to_s)
  end

  def resource_id(key) = lookup(@resources, key, 'resource').id
  def service_id(key) = lookup(@services, key, 'service').id
  def contact_id(key) = lookup(@contacts, key, 'contact').id

  def resource_key(id) = key_for(@resources, id)
  def service_key(id) = key_for(@services, id)
  def contact_key(id) = key_for(@contacts, id)

  # [{ id:, key:, name: }] of the records created from the fixture.
  def resources = rows(@resources)
  def services = rows(@services)
  def contacts = rows(@contacts)

  private

  def lookup(map, key, kind)
    map.fetch(key.to_s) { raise ArgumentError, "Unknown #{kind} key in a fixture expectation: #{key}" }
  end

  def key_for(map, id)
    map.find { |_key, record| record.id == id }&.first
  end

  def rows(map)
    map.map { |key, record| { id: record.id, key: key, name: record.name } }
  end
end
