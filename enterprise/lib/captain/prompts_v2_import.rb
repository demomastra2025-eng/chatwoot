# frozen_string_literal: true

# Reads the prompts-v2 pack of one clinic, the JSON file that rake onelink:captain:apply_prompt_pack (Captain::PromptPack) applies:
#
#   { "account_id": 43,
#     "shared_block": "<the clinic context: Account#captain_clinic_context>",
#     "assistants": [{ "id": 77, "routing_description": "<the card>", "description": "<the agent prompt>" }, ...] }
#
# payload is the file as a hash with string keys and sha256 the SHA-256 of its bytes, both from one read of the file. Refused is
# raised unless the file has exactly that shape: no missing or unknown key, no empty text, every id a positive integer listed
# once. It only reads: the dry run, the backup, the write and the roll back are Captain::PromptPack.
class Captain::PromptsV2Import
  Refused = Class.new(StandardError)

  TOP_KEYS = %w[account_id shared_block assistants].freeze
  ASSISTANT_KEYS = %w[id routing_description description].freeze
  ASSISTANT_TEXTS = %w[description routing_description].freeze

  def initialize(path:)
    @path = path.to_s
  end

  # The file as a hash with string keys, checked against the shape in the header of this class; Refused otherwise.
  def payload
    read! unless defined?(@payload)
    @payload
  end

  # The SHA-256 of the bytes that payload was parsed from, as hex: what `sha256sum <file>` prints
  def sha256
    read! unless defined?(@sha256)
    @sha256
  end

  private

  def read!
    raise Refused, 'a pack file is required' if @path.blank?
    raise Refused, "file not found: #{@path}" unless File.file?(@path)

    bytes = File.binread(@path)
    payload = JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8).delete_prefix("\u{FEFF}"))
    check_payload!(payload)
    @sha256 = Digest::SHA256.hexdigest(bytes)
    @payload = payload
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
