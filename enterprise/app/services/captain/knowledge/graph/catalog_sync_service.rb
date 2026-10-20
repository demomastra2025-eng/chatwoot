# frozen_string_literal: true

class Captain::Knowledge::Graph::CatalogSyncService
  def self.sync_account!(account)
    new(account).sync!
  end

  def initialize(account)
    @account = account
    @upserter = Captain::Knowledge::Graph::UpsertService.new(account: account, assistant_id: nil, visibility: :general)
  end

  def sync!
    service_nodes = sync_services
    sync_resources(service_nodes)
  end

  private

  def sync_services
    @account.scheduling_services.active.each_with_object({}) do |service, acc|
      attrs = {
        available: true,
        primary_price_kzt: service.base_price,
        duration_min: service.duration_min
      }.compact
      node = @upserter.upsert_node(
        node_type: :service,
        canonical_name: service.name,
        aliases: [service.name],
        attributes: attrs,
        source_key: "scheduling_service:#{service.id}",
        source_type: 'Scheduling::Service',
        source_id: service.id
      )
      acc[service.id] = node if node
    end
  end

  def sync_resources(service_nodes)
    @account.scheduling_resources.available_for_scheduling.includes(:service_prices).find_each do |resource|
      attrs = {
        available: true,
        slot_duration_min: resource.slot_duration_min
      }.compact
      specialist_node = @upserter.upsert_node(
        node_type: :specialist,
        canonical_name: resource.name,
        aliases: [resource.name, resource.name.split.first].compact.uniq,
        attributes: attrs,
        source_key: "scheduling_resource:#{resource.id}",
        source_type: 'Scheduling::Resource',
        source_id: resource.id
      )
      next unless specialist_node

      sync_resource_specialty(specialist_node, resource)
      sync_resource_services(specialist_node, resource, service_nodes)
    end
  end

  def sync_resource_specialty(specialist_node, resource)
    return if resource.specialty.blank?

    spec_node = @upserter.upsert_node(
      node_type: :specialty,
      canonical_name: resource.specialty,
      aliases: [resource.specialty],
      attributes: { available: true },
      source_key: "scheduling_resource_specialty:#{resource.id}"
    )
    return unless spec_node

    @upserter.upsert_edge(source_node: specialist_node, target_node: spec_node, relation_type: :has_specialty)
  end

  def sync_resource_services(specialist_node, resource, service_nodes)
    resource.service_prices.each do |sp|
      service_node = service_nodes[sp.service_id]
      next unless service_node

      @upserter.upsert_edge(
        source_node: specialist_node,
        target_node: service_node,
        relation_type: :performs_service,
        properties: { price_kzt: sp.price }
      )
    end
  end
end
