# frozen_string_literal: true

class Llm::Evals::Runner
  def initialize(account: nil, pack_ids: nil, include_live: false, max_cases: nil)
    @account = account
    @pack_ids = Array(pack_ids).filter_map { |id| id.to_s.presence }
    @include_live = include_live
    @max_cases = max_cases
  end

  def call
    ::Llm::Evals::CollectionResult.new(suites: selected_packs.map { |pack| run_pack(pack) })
  end

  private

  def selected_packs
    packs = if @pack_ids.present?
              @pack_ids.map { |id| ::Llm::Evals::PackRegistry.find!(id) }
            else
              ::Llm::Evals::PackRegistry.default_packs(include_live: @include_live)
            end

    packs.reject { |pack| pack.live_model && !@include_live }
  end

  def run_pack(pack)
    pack.build(account: @account, max_cases: @max_cases).call
  end
end
