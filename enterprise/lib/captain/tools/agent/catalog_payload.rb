# frozen_string_literal: true

# The compact answer of the catalog search tools for the patient-facing agent. The model re-reads every tool result on every later
# step of a run, so a result holds only what the model needs to choose and to call the next tool: ids, names, prices, the status of
# the search. It never holds the admin view of a record (custom attributes, timestamps, account ids, compensation fields, empty
# fields). Staff and Copilot keep the full payload of the admin API; this module is used for the agent scope only.
module Captain::Tools::Agent::CatalogPayload
  # A service answer lists at most this many entries per mention: more would only be read again on every step.
  SERVICE_LIMIT = 10
  # The short English text of an empty list of queries: the catalog is never dumped, the model searches again with service names.
  REFINE_QUERY_INSTRUCTION = 'The catalog is not listed without queries. Search again with queries: the names of the services ' \
                             '(or their category) that the patient asked about.'
  # The hint of an empty query lists the categories so that the model can pick words; this many at most.
  CATEGORY_HINT_LIMIT = 15

  module_function

  # One service: id, name, base price, duration and the specialists who offer it as "id name" (with their own price in brackets only
  # when it differs from the base price). components: the services of a package, each one as { id, name, price }. A MedElement
  # service shows no duration: its duration_min is the column default, and the real length depends on the specialist (a slot search
  # answers it).
  def service(service, links, components: [])
    {
      id: service.id,
      name: service.name.to_s.squish,
      price: service.base_price,
      duration_min: (service.duration_min.presence unless service.medelement_service?),
      active: (false unless service.active),
      doctors: doctor_entries(links, service.base_price).presence,
      component_services: components.presence,
      components_total_price: (components.sum { |item| item[:price].to_i } if components.present?)
    }.compact
  end

  # links: [{ resource_id:, resource_name:, price: }] of the active price links of one service.
  def doctor_entries(links, base_price)
    links.map do |link|
      entry = "#{link[:resource_id]} #{link[:resource_name].to_s.squish}"
      link[:price] == base_price ? entry : "#{entry} (#{link[:price]})"
    end
  end

  # One specialist or room of a search answer: id, name, specialty. The names of the cabinets only for a specialist who sits in
  # more than one (a booking never needs a cabinet: the server picks a free one); never the codes or any other MedElement field.
  def resource(row)
    {
      id: row[:id],
      name: row[:name].to_s.squish,
      specialty: row[:specialty].to_s.squish.presence,
      active: (false if row[:active] == false),
      best_match: (true if row[:best_match]),
      cabinets: cabinet_names(row[:custom_attributes]).presence
    }.compact
  end

  def cabinet_names(custom_attributes)
    cabinets = Array(custom_attributes.to_h['medelement_cabinets']).select { |cabinet| cabinet.is_a?(Hash) }
    return [] if cabinets.size < 2

    cabinets.filter_map do |cabinet|
      Integrations::Medelement::CabinetAttributes.cabinet_name(cabinet) || Integrations::Medelement::CabinetAttributes.cabinet_number(cabinet)
    end.uniq
  end

  # The wrapper of a search answer: the counts, the paging and the status of the search, each one only when it says something.
  def search_envelope(total_count:, has_more:, next_offset:, page_status:, exact_name_matches:)
    {
      total_count: total_count,
      has_more: (true if has_more),
      next_offset: (next_offset if has_more),
      page_status: (page_status unless page_status == 'returned'),
      exact_name_matches: (exact_name_matches if exact_name_matches.to_i.positive?)
    }.compact
  end
end
