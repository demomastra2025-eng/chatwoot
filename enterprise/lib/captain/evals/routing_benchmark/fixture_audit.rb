# frozen_string_literal: true

# What the fixtures lack for gate items a and f, found without calling a model (the gate itself only finds out after a paid
# run, see Gate coverage):
#   - an appointment expectation that does not pin the start time (`params.starts_at`, or the symbolic `starts_at`): a booking at
#     the wrong time would not be noticed on that turn. The strict loader (Fixture) refuses such an operation, so the audit only
#     counts them (item a);
#   - a turn in which the customer asks for a person but the fixture does not expect a handoff (`staff_handoff: true`, or the older
#     `human_request: true`), or says `staff_handoff: false` / `human_request: false` against the wording;
#   - the lint of the calendar (FixtureLint): a start outside every doctor's work window or on a busy slot.
# `ok?` holds when nothing is missing and the fixtures hold at least one pinned expectation and one request for a person.
class Captain::Evals::RoutingBenchmark::FixtureAudit
  Gap = Struct.new(:fixture, :dialogue, :turn, :problem, keyword_init: true)

  # fixtures: { file name => Fixture }. A file the strict loader refuses is named in the error.
  def self.load(paths) = new(paths.sort.to_h { |path| [File.basename(path), load_fixture(path)] })

  def self.load_fixture(path)
    Captain::Evals::RoutingBenchmark::Fixture.load(path)
  rescue Captain::Evals::RoutingBenchmark::Fixture::Invalid => e
    raise Captain::Evals::RoutingBenchmark::Fixture::Invalid, "#{File.basename(path)}: #{e.message}"
  end

  def initialize(fixtures)
    @fixtures = fixtures
  end

  def result
    @result ||= audit
  end

  def ok?
    operations = result[:operations]
    result[:gaps].empty? && operations[:specific].positive? && operations[:specific] == operations[:expected] && result[:human_requests][:flagged].positive?
  end

  def markdown
    data = result
    lines = ['# Routing benchmark fixtures', '',
             "Fixtures: #{data[:fixtures]}; turns: #{data[:turns]}.",
             "Item a: #{data[:operations][:specific]} of #{data[:operations][:expected]} appointment expectations pin the start time.",
             "Item f: #{data[:human_requests][:flagged]} turns that ask for a person expect a handoff; #{data[:human_requests][:unmarked]} do not.",
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
          operations(turn, counts)
          person(turn, where, counts, gaps)
        end
      end
      lint(name, fixture, gaps)
    end
    { fixtures: @fixtures.size, turns: counts[:turns], operations: counts.slice(:expected, :specific),
      human_requests: counts.slice(:flagged, :unmarked), gaps: gaps }
  end

  # The strict loader refuses an appointment operation that pins no start, so every expectation that gets here is specific; the count
  # stays in the report (item a), and `ok?` still compares the two.
  def operations(turn, counts)
    gate = Captain::Evals::RoutingBenchmark::Gate
    gate.expected_operations('expectation' => turn['expect']).each do |operation|
      counts[:expected] += 1
      counts[:specific] += 1 if gate.specific?(operation)
    end
  end

  # The customer asks for a person. The fixture expects the handoff (`staff_handoff: true`), or in the older form marks the turn.
  def person(turn, where, counts, gaps)
    expect = turn['expect']
    detected = Captain::Evals::RoutingBenchmark::HumanRequest.match?(turn['customer'])
    expected = expect['human_request'] == true || expect['staff_handoff'] == true
    counts[:flagged] += 1 if expect['human_request'] == true || (detected && expect['staff_handoff'] == true)
    return unless detected && !expected

    counts[:unmarked] += 1
    contradicted = expect['human_request'] == false || expect['staff_handoff'] == false
    gaps << Gap.new(**where, problem: contradicted ? 'the customer asks for a person, but the fixture expects no handoff' : 'the customer asks for a person: add staff_handoff: true')
  end

  def lint(name, fixture, gaps)
    Captain::Evals::RoutingBenchmark::FixtureLint.new(fixture).problems.each do |problem|
      gaps << Gap.new(fixture: name, dialogue: problem[:dialogue], turn: problem[:turn], problem: problem[:message])
    end
  end

end
