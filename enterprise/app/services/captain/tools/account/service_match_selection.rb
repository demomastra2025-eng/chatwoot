# frozen_string_literal: true

# Which of the services found for the mentions of one call of the service search are offered. Each mention keeps the services within
# `band` of its best score (a closer service exists, and the twins of a name, "with" and "without" something, score within a few
# hundredths of each other), at most `limit`; then the whole answer is cut to `cap` services by taking the last (weakest) service of
# the mention that has the most, so that every mention keeps its best one. Checked 27.10 on 345 mentions of five clinics: with a band of
# 0.05 and 3 services per mention the right service is among the answers for 89% of the real services (90% without any cut) and first
# for 80%, with 1.7 services per mention instead of 3.8.
class Captain::Tools::Account::ServiceMatchSelection
  # results: [{ mention:, hits: [Scheduling::ServiceIndex::Hit] }], hits best first. The hits are replaced by the offered ones.
  def initialize(band:, cap:)
    @band = band
    @cap = cap
  end

  def call(results, limit)
    results.each do |result|
      best = result[:hits].first&.score
      result[:hits] = result[:hits].select { |hit| hit.score >= best - @band }.first(limit) if best
    end
    cut_to_cap(results)
  end

  private

  def cut_to_cap(results)
    while results.sum { |result| result[:hits].size } > @cap
      longest = results.select { |result| result[:hits].size > 1 }.max_by { |result| [result[:hits].size, -result[:hits].last.score] }
      break unless longest

      longest[:hits].pop
    end
    results
  end
end
