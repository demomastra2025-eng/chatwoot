# frozen_string_literal: true

# What the fixtures lack for gate items a and f, found without calling a model (the gate itself only finds out after a paid
# run, see Gate coverage):
#   - an appointment expectation that does not name the doctor (`resource`), the time (`starts_at`) and, for a booking or a
#     move, the service or the patient (`service`, `patient`, `patient_name`): a booking with the wrong doctor or time would
#     not be noticed on that turn;
#   - a turn in which the customer asks for a person but the fixture does not say `human_request: true` (the detector would
#     decide at run time), or says `false` against the wording.
# `ok?` holds when nothing is missing and the fixtures hold at least one specific expectation and one request for a person.
class Captain::Evals::RoutingBenchmark::FixtureAudit
  Gap = Struct.new(:fixture, :dialogue, :turn, :problem, keyword_init: true)

  # fixtures: { file name => Fixture }
  def self.load(paths) = new(paths.sort.to_h { |path| [File.basename(path), Captain::Evals::RoutingBenchmark::Fixture.load(path)] })

  def initialize(fixtures)
    @fixtures = fixtures
  end

  def result
    @result ||= audit
  end

  def ok?
    result[:gaps].empty? && result[:operations][:specific].positive? && result[:human_requests][:flagged].positive?
  end

  def markdown
    data = result
    lines = ['# Routing benchmark fixtures', '',
             "Fixtures: #{data[:fixtures]}; turns: #{data[:turns]}.",
             "Item a: #{data[:operations][:specific]} of #{data[:operations][:expected]} appointment expectations name the doctor, the time and the service or patient.",
             "Item f: #{data[:human_requests][:flagged]} turns are marked human_request: true; #{data[:human_requests][:unmarked]} ask for a person without the mark.",
             "Ready for the gate: #{ok? ? 'yes' : 'no'}.", '']
    lines << 'Nothing is missing.' if data[:gaps].empty?
    lines += data[:gaps].map { |gap| "- #{gap.fixture} #{gap.dialogue} turn #{gap.turn}: #{gap.problem}" }
    "#{lines.join("\n")}\n"
  end

  private

  def audit
    gaps = []
    counts = { turns: 0, expected: 0, specific: 0, flagged: 0, unmarked: 0 }
    @fixtures.each do |name, fixture|
      fixture.dialogues.each do |dialogue|
        dialogue.fetch('turns').each_with_index do |turn, index|
          counts[:turns] += 1
          where = { fixture: name, dialogue: dialogue['id'], turn: index + 1 }
          operations(turn, where, counts, gaps)
          person(turn, where, counts, gaps)
        end
      end
    end
    { fixtures: @fixtures.size, turns: counts[:turns], operations: counts.slice(:expected, :specific),
      human_requests: counts.slice(:flagged, :unmarked), gaps: gaps }
  end

  def operations(turn, where, counts, gaps)
    gate = Captain::Evals::RoutingBenchmark::Gate
    gate.expected_operations('expectation' => turn['expect']).each do |operation|
      counts[:expected] += 1
      if gate.specific?(operation)
        counts[:specific] += 1
      else
        gaps << Gap.new(**where, problem: "#{kind_of(operation)} expectation lacks #{missing(operation).join(', ')}")
      end
    end
  end

  def person(turn, where, counts, gaps)
    flag = turn.dig('expect', 'human_request')
    detected = Captain::Evals::RoutingBenchmark::HumanRequest.match?(turn['customer'])
    counts[:flagged] += 1 if flag == true
    return unless detected && flag != true

    counts[:unmarked] += 1
    gaps << Gap.new(**where, problem: flag.nil? ? 'the customer asks for a person: add human_request: true' : 'human_request: false, but the customer asks for a person')
  end

  def kind_of(operation) = Captain::Evals::RoutingBenchmark::OperationCheck.kind_of(operation)

  def missing(operation)
    lacking = %w[resource starts_at].reject { |key| operation[key].present? }
    lacking << 'service or patient' if kind_of(operation) != 'cancel' && %w[service patient patient_name].none? { |key| operation[key].present? }
    lacking
  end
end
