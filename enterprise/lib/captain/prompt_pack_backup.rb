# frozen_string_literal: true

# The backup that Captain::PromptPack writes before it applies a pack, and reads to roll the pack back:
# <dir>/prompt_pack_backup_<account>_<UTC timestamp>.json, readable by its owner only, never overwritten.
#
#   { "kind": "onelink_prompt_pack_backup", "version": 1, "account_id": 43, "taken_at": "2026-10-25T21:04:05.123Z",
#     "source": "pack /tmp/aliya_43.json",
#     "clinic_context": "<the stored clinic block, empty when the account had none>",
#     "assistants": [{ "id": 77, "description": "<the stored prompt>", "routing_description": "<the stored card, or null>" }] }
class Captain::PromptPackBackup
  KIND = 'onelink_prompt_pack_backup'
  VERSION = 1
  KEYS = %w[kind version account_id taken_at source clinic_context assistants].freeze
  ASSISTANT_KEYS = %w[id description routing_description].freeze

  class << self
    # Writes the stored texts of a Captain::PromptPack::Plan (the clinic block and every listed agent) and returns the path
    def write(plan, dir:, source:)
      FileUtils.mkdir_p(dir)
      data = {
        kind: KIND, version: VERSION, account_id: plan.account.id, taken_at: Time.current.utc.iso8601(3), source: source,
        clinic_context: plan.stored_context,
        assistants: plan.assistants.map do |assistant|
          { id: assistant.id, description: assistant.attribute_in_database('description'),
            routing_description: assistant.attribute_in_database('routing_description') }
        end
      }
      path = free_path(dir, plan.account.id)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600, encoding: 'UTF-8') { |file| file.write(JSON.pretty_generate(data)) }
      path
    end

    # The Captain::PromptPack::Target of a backup file; Refused unless the file has exactly the shape above
    def read(path)
      refuse!('a backup file is required') if path.blank?
      refuse!("file not found: #{path}") unless File.file?(path)

      data = JSON.parse(File.read(path, encoding: 'bom|utf-8'))
      check!(data)
      Captain::PromptPack::Target.new(account_id: data['account_id'], clinic_context: data['clinic_context'],
                                      assistants: data['assistants'], source: "backup #{path} (taken at #{data['taken_at']})")
    rescue JSON::ParserError => e
      refuse!("not valid JSON: #{e.message.truncate(200)}")
    end

    private

    def free_path(dir, account_id)
      base = File.join(dir, "prompt_pack_backup_#{account_id}_#{Time.current.utc.strftime('%Y%m%d-%H%M%S-%L')}")
      ["#{base}.json", *(1..9).map { |number| "#{base}-#{number}.json" }].find { |path| !File.exist?(path) } ||
        refuse!("no free backup file name for #{base}")
    end

    def check!(data)
      refuse!('not a prompt pack backup: the file must hold one JSON object') unless data.is_a?(Hash)
      refuse!("not a prompt pack backup: kind must be #{KIND}") unless data['kind'] == KIND
      refuse!("unknown backup version #{data['version'].inspect}, expected #{VERSION}") unless data['version'] == VERSION
      refuse!("the backup must have exactly the keys #{KEYS.join(', ')}") unless data.keys.sort == KEYS.sort
      refuse!('account_id must be a positive integer') unless positive_integer?(data['account_id'])
      refuse!('clinic_context must be a string') unless data['clinic_context'].is_a?(String)

      check_assistants!(data['assistants'])
    end

    def check_assistants!(entries)
      refuse!('assistants must be a non-empty list') unless entries.is_a?(Array) && entries.any?

      entries.each_with_index { |entry, index| check_assistant!(entry, index) }
      duplicates = entries.pluck('id').tally.select { |_id, count| count > 1 }.keys
      refuse!("assistants lists an id more than once: #{duplicates.join(', ')}") if duplicates.any?
    end

    def check_assistant!(entry, index)
      unless entry.is_a?(Hash) && entry.keys.sort == ASSISTANT_KEYS.sort
        refuse!("assistants[#{index}] must have exactly the keys #{ASSISTANT_KEYS.join(', ')}")
      end
      refuse!("assistants[#{index}].id must be a positive integer") unless positive_integer?(entry['id'])
      refuse!("assistants[#{index}].description must be a string") unless entry['description'].is_a?(String)
      return if entry['routing_description'].nil? || entry['routing_description'].is_a?(String)

      refuse!("assistants[#{index}].routing_description must be a string or null")
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def refuse!(message)
      raise Captain::PromptPack::Refused, message
    end
  end
end
