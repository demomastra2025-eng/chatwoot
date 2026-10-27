# frozen_string_literal: true

# The parts of the package services in an answer of the service search. A package is a service named "Комплекс: УЗИ + ЭКГ"; the patient
# agent gets its parts as { id, name, price } with the total price. Each part is resolved to the nearest single service of the catalog
# by the same vector search as the mentions, in one more embedding request that is made only when a package is among the answers.
class Captain::Tools::Account::ServicePackageComponents
  # How many nearest services of a part are looked at to pick the part (a "repeat visit" service is the second choice).
  CANDIDATES = 3

  # scope: the services that may be found; model/min_score: the embedding model in force and its threshold; embed: a callable that gives
  # the vectors of a list of texts (the tool's embedding request, with its timeout).
  def initialize(scope:, model:, min_score:, embed:)
    @scope = scope
    @model = model
    @min_score = min_score
    @embed = embed
  end

  # { package service id => [{ id:, name:, price: }] } for the packages of `services` that have two or more resolved parts.
  def call(services)
    parts_by_package = services.index_with { |service| parts(service) }.select { |_, parts| parts.size >= 2 }
    return {} if parts_by_package.empty?

    hits_by_part = nearest_services(parts_by_package.values.flatten.uniq)
    components = parts_by_package.to_h { |package, parts| [package.id, resolved(parts, hits_by_part)] }
    components.select { |_, items| items.size >= 2 }
  end

  private

  def parts(service)
    return [] unless service.name.to_s.include?('+')

    service.name.to_s.split(':', 2).last.to_s.split('+').map(&:strip).compact_blank
  end

  # { part text => [Scheduling::Service] } among the single services (a package is never the part of a package).
  def nearest_services(texts)
    singles = @scope.where.not('scheduling_services.name LIKE ?', '%+%')
    hits = Scheduling::ServiceIndex.nearest(singles, @embed.call(texts), model: @model, limit: CANDIDATES)
    texts.zip(hits).to_h { |text, found| [text, found.select { |hit| hit.score >= @min_score }.map(&:service)] }
  end

  def resolved(parts, services_by_part)
    components = parts.filter_map do |part|
      services = services_by_part.fetch(part, [])
      match = services.find { |item| !item.name.to_s.match?(/повторн/i) } || services.first
      { id: match.id, name: match.name, price: match.base_price } if match
    end
    components.uniq { |item| item[:id] }
  end
end
