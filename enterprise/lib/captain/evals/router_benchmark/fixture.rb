# frozen_string_literal: true

# The inputs of the router benchmark, loaded strictly: the clinic graphs (the clinic_graphs.json export: account => { name,
# assistants: [{ id, name, routing_description, enabled_tool_ids, entry_eligible }] }), the scenarios (router_scenarios.json) and,
# for CARDS=proposed, the routing descriptions of the reviewed prompt migration (the same YAML the rake task applies). The
# candidates of a suite go through the same Captain::Routing::Candidate and competence card code as the live router.
#
# A reply suggestion scenario sets sticky (the sticky agent of the dialog, see Captain::ReplySuggestion::StickyAgent: the current
# agent of the turn while the saved session has none) or suggestion: true, and may set anchor (the anchor of the channel, which
# answers a suggestion whose answers name no agent while no agent leads the dialog, see DecisionRouter::Questions). A suggestion
# scenario may expect undecided: the escalation names no agent either and the manager answers (DecisionRouter::UndecidedError).
class Captain::Evals::RouterBenchmark::Fixture
  class Invalid < StandardError; end

  KEY = /\A(?:stay_current|human_handoff|undecided|route_agent_\d+|council_\d+_\d+(?:_\d+)?)\z/
  UNDECIDED = 'undecided'
  CARD_SOURCES = %w[prod proposed].freeze

  Suite = Struct.new(:name, :account_id, :clinic, :candidates, :scenarios, keyword_init: true)

  attr_reader :suites

  def self.load(graphs:, scenarios:, cards: 'proposed', proposals: nil)
    parsed_proposals = proposals && YAML.safe_load_file(proposals)
    new(JSON.parse(File.read(graphs)), JSON.parse(File.read(scenarios)), cards: cards, proposals: parsed_proposals)
  end

  # graphs, scenarios: parsed JSON; proposals: the parsed migration YAML (needed for cards: 'proposed').
  def initialize(graphs, scenarios, cards: 'proposed', proposals: nil)
    raise Invalid, "CARDS must be one of #{CARD_SOURCES.join(', ')}" unless CARD_SOURCES.include?(cards.to_s)
    raise Invalid, 'CARDS=proposed needs the proposals of the prompt migration' if cards.to_s == 'proposed' && proposals.blank?

    @graphs = graphs.to_h
    @cards = cards.to_s
    @proposed = Array(proposals.to_h['assistants']).to_h { |row| [row['assistant_id'].to_i, row['routing_description'].to_s] }
    @suites = Array(scenarios.to_h['suites']).map { |suite| build_suite(suite.to_h) }
    check_unique_ids!
  end

  def scenario_count = @suites.sum { |suite| suite.scenarios.size }

  private

  def build_suite(suite)
    account_id = suite['account_id'].to_s
    graph = @graphs[account_id] || raise(Invalid, "Suite #{suite['suite']}: account #{account_id} is not in the graphs")
    candidates = candidates_for(suite, graph)
    scenarios = Array(suite['scenarios']).map { |scenario| check_scenario!(suite['suite'], scenario.to_h, candidates.map(&:id)) }
    Suite.new(name: suite['suite'].to_s, account_id: account_id.to_i, clinic: graph['name'], candidates: candidates, scenarios: scenarios)
  end

  # The listed candidates, or every agent of the account that may answer patients (internal assistants and the listed exclusions
  # left out); the card text comes from the export (prod) or from the reviewed proposal (proposed).
  def candidates_for(suite, graph)
    rows = Array(graph['assistants']).map(&:to_h)
    (candidate_ids(suite, rows) - Array(suite['excluded']).map(&:to_i)).map do |id|
      row = rows.find { |item| item['id'].to_i == id } || raise(Invalid, "Suite #{suite['suite']}: agent #{id} is not in the graph")
      Captain::Routing::Candidate.from_export(row, routing_description: (@proposed[id] if @cards == 'proposed'))
    end
  end

  def candidate_ids(suite, rows)
    listed = Array(suite['candidates']).map(&:to_i)
    listed.presence || rows.reject { |row| row['entry_eligible'] == false }.map { |row| row['id'].to_i }
  end

  def check_scenario!(suite_name, scenario, candidate_ids)
    label = "#{suite_name}/#{scenario['id']}"
    raise Invalid, "#{label}: id and message are required" if scenario['id'].blank? || scenario['message'].to_s.strip.blank?

    expected = scenario['expected'].to_s
    raise Invalid, "#{label}: expected #{expected.inspect} is not a criteria key" unless expected.match?(KEY)
    raise Invalid, "#{label}: expected names an agent that is not a candidate" unless (expected.scan(/\d+/).map(&:to_i) - candidate_ids).empty?

    check_suggestion!(label, scenario, candidate_ids)
    check_current!(label, expected, scenario['current'].presence || scenario['sticky'])
    scenario
  end

  def check_suggestion!(label, scenario, candidate_ids)
    %w[sticky anchor].each do |key|
      next if scenario[key].blank? || candidate_ids.include?(scenario[key].to_i)

      raise Invalid, "#{label}: #{key} #{scenario[key]} is not a candidate"
    end
    raise Invalid, "#{label}: a sticky agent replaces the saved current agent" if scenario['sticky'].present? && scenario['current'].present?

    check_undecided!(label, scenario)
  end

  def check_undecided!(label, scenario)
    raise Invalid, "#{label}: only a suggestion can be undecided" if scenario['expected'].to_s == UNDECIDED && !suggestion?(scenario)
  end

  def suggestion?(scenario)
    scenario.key?('sticky') || scenario['suggestion'] == true
  end

  def check_current!(label, expected, current)
    raise Invalid, "#{label}: stay_current needs a current agent" if expected == 'stay_current' && current.blank?
    raise Invalid, "#{label}: route_agent_<current> is stay_current" if expected == "route_agent_#{current}"
  end

  def check_unique_ids!
    ids = @suites.flat_map { |suite| suite.scenarios.pluck('id') }
    duplicates = ids.tally.select { |_id, count| count > 1 }.keys
    raise Invalid, "Duplicate scenario ids: #{duplicates.join(', ')}" if duplicates.any?
  end
end
