# frozen_string_literal: true

# Writes the prompts v2 of one clinic from a JSON file (rake onelink:captain:apply_prompts_v2):
#
#   { "account_id": 43,
#     "shared_block": "<the clinic context: Account#captain_clinic_context>",
#     "assistants": [{ "id": 77, "routing_description": "<the card>", "description": "<the agent prompt>" }, ...] }
#
# A dry run (the default) writes nothing. It prints a unified diff from the stored text to the text of the file for the clinic
# context and for the prompt and the card of every listed agent. apply: true prints the same and writes the clinic context and
# every listed agent in one transaction: all of it or nothing. Agents of the account that the file does not list are never
# written.
#
# Nothing is written, and Refused is raised, when the file is not of that shape, the account does not exist, an id is not an agent
# of that account, or a text would not be saved as it is (the rules of Account#captain_clinic_context, the validations of the
# account and of Captain::Assistant, or legacy rules of an agent that its save would merge into the prompt).
class Captain::PromptsV2Import
  Refused = Class.new(StandardError)

  TOP_KEYS = %w[account_id shared_block assistants].freeze
  ASSISTANT_KEYS = %w[id routing_description description].freeze
  ASSISTANT_TEXTS = %w[description routing_description].freeze

  def initialize(path:, out: $stdout)
    @path = path.to_s
    @out = out
  end

  # Prints the change and, with apply: true, writes it. Returns true; raises Refused, with nothing written, on any problem.
  def call(apply: false)
    payload = read_payload
    account = Account.find_by(id: payload['account_id'])
    raise Refused, "account #{payload['account_id']} does not exist" if account.nil?

    if apply
      ActiveRecord::Base.transaction do
        account.lock!
        write!(account, report!(account, payload, apply: true))
      end
    else
      report!(account, payload, apply: false)
    end
    true
  end

  # The file as a hash with string keys, checked against the shape in the header of this class; Refused otherwise.
  # Captain::PromptPack reads its packs with it.
  def payload
    @payload ||= read_payload
  end

  private

  # Assigns the texts of the file, prints what changes and returns the listed agents; raises Refused when a text would not be
  # saved as it is. lock: the rows of the agents are locked for the transaction of the write.
  def report!(account, payload, apply:)
    assistants = listed_assistants(account, payload['assistants'], lock: apply)
    stored_context = account.captain_clinic_context
    account.captain_clinic_context = payload['shared_block']
    account.valid?

    @out.puts "Prompts v2 for account #{account.id} «#{account.name}» from #{@path}: " \
              "#{apply ? 'writing in one transaction' : 'dry run, nothing is written (pass apply=true to write)'}."
    print_diff('clinic context', stored_context, account.captain_clinic_context)
    assistants.each { |assistant| print_assistant(assistant) }

    problems = account.errors.full_messages.map { |message| "account #{account.id}: #{message}" }
    problems += assistants.flat_map { |assistant| assistant_problems(assistant, payload) }
    raise Refused, problems.join("\n") if problems.any?

    print_summary(stored_context != account.captain_clinic_context, assistants, apply)
    assistants
  end

  def write!(account, assistants)
    account.save!
    assistants.each(&:save!)
  end

  # The listed agents of the account, in the order of the file, with the texts of the file assigned and validated. Refused when an
  # id is not an agent of this account.
  def listed_assistants(account, entries, lock:)
    ids = entries.pluck('id')
    scope = Captain::Assistant.where(account_id: account.id, id: ids)
    records = (lock ? scope.lock : scope).index_by(&:id)
    foreign = ids - records.keys
    raise Refused, "not agents of account #{account.id}: #{describe_foreign(foreign)}" if foreign.any?

    entries.map do |entry|
      records.fetch(entry['id']).tap do |assistant|
        assistant.assign_attributes(entry.slice(*ASSISTANT_TEXTS))
        assistant.valid?
      end
    end
  end

  def describe_foreign(ids)
    owners = Captain::Assistant.where(id: ids).pluck(:id, :account_id).to_h
    ids.map { |id| owners.key?(id) ? "#{id} (account #{owners[id]})" : "#{id} (does not exist)" }.join(', ')
  end

  def print_assistant(assistant)
    label = "assistant #{assistant.id} «#{assistant.name}»"
    print_diff("#{label} description", assistant.description_in_database, assistant.description)
    print_diff("#{label} routing_description", assistant.routing_description_in_database, assistant.routing_description)
  end

  def print_diff(label, stored, wanted)
    diff = Captain::TextDiff.unified(stored, wanted, from: "#{label} (stored)", to: "#{label} (file)")
    @out.puts(diff.presence || "= #{label}: unchanged")
  end

  # The validation errors of the agent, and a prompt that its save would change (legacy rules merged in by the callbacks of
  # Captain::Assistant): the stored text must be the text of the file.
  def assistant_problems(assistant, payload)
    problems = assistant.errors.full_messages.map { |message| "assistant #{assistant.id}: #{message}" }
    wanted = payload['assistants'].find { |entry| entry['id'] == assistant.id }['description']
    if assistant.description != wanted
      problems << "assistant #{assistant.id}: its save would add legacy rules to the prompt of the file; save the agent once in " \
                  'the dashboard to move them, then run this again'
    end
    problems
  end

  def print_summary(context_changed, assistants, apply)
    changed = assistants.select { |assistant| assistant.changed.intersect?(ASSISTANT_TEXTS) }.map(&:id)
    @out.puts "#{apply ? 'Written' : 'Would write'}: clinic context #{context_changed ? 'changed' : 'unchanged'}; " \
              "agents changed: #{changed.any? ? changed.join(', ') : 'none'} (listed: #{assistants.map(&:id).join(', ')})."
  end

  # The file as a hash with string keys; Refused unless it has exactly the shape in the header of this class
  def read_payload
    raise Refused, 'json_path is required' if @path.blank?
    raise Refused, "file not found: #{@path}" unless File.file?(@path)

    payload = JSON.parse(File.read(@path, encoding: 'bom|utf-8'))
    check_payload!(payload)
    payload
  rescue JSON::ParserError => e
    raise Refused, "not valid JSON: #{e.message.truncate(200)}"
  end

  def check_payload!(payload)
    raise Refused, 'the file must hold one JSON object' unless payload.is_a?(Hash)

    check_keys!('the file', payload, TOP_KEYS)
    raise Refused, 'account_id must be a positive integer' unless positive_integer?(payload['account_id'])
    raise Refused, 'shared_block must be a non-empty string' unless text?(payload['shared_block'])

    check_assistants!(payload['assistants'])
  end

  def check_assistants!(entries)
    raise Refused, 'assistants must be a non-empty list' unless entries.is_a?(Array) && entries.any?

    entries.each_with_index { |entry, index| check_assistant!(entry, index) }
    duplicates = entries.pluck('id').tally.select { |_id, count| count > 1 }.keys
    raise Refused, "assistants lists an id more than once: #{duplicates.join(', ')}" if duplicates.any?
  end

  def check_assistant!(entry, index)
    raise Refused, "assistants[#{index}] must be an object" unless entry.is_a?(Hash)

    check_keys!("assistants[#{index}]", entry, ASSISTANT_KEYS)
    raise Refused, "assistants[#{index}].id must be a positive integer" unless positive_integer?(entry['id'])

    ASSISTANT_TEXTS.each do |key|
      raise Refused, "assistants[#{index}].#{key} must be a non-empty string" unless text?(entry[key])
    end
  end

  def check_keys!(where, hash, expected)
    missing = expected - hash.keys
    unknown = hash.keys - expected
    return if missing.empty? && unknown.empty?

    raise Refused, "#{where} must have exactly the keys #{expected.join(', ')} " \
                   "(missing: #{missing.join(', ').presence || '-'}; unknown: #{unknown.join(', ').presence || '-'})"
  end

  def positive_integer?(value)
    value.is_a?(Integer) && value.positive?
  end

  def text?(value)
    value.is_a?(String) && value.strip.present?
  end
end
