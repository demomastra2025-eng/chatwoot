class Captain::Tools::Operations::DealUpdateGuard
  ERROR_MESSAGE = 'update_deal target does not match the latest user message; ask a clarifying question before updating another deal'.freeze
  SELECTION_CONTEXT_TTL = 2.minutes
  RUSSIAN_TOKEN_ENDINGS = %w[ами ями ого ему ием ыми ими ов ев ей ой ый ий ая ое ые ых им ом ем ам ям ах ях а я у ю е ы и о].freeze

  def initialize(account:, conversation:, current_contact:, current_deal:, selection_context: nil)
    @account = account
    @conversation = conversation
    @current_contact = current_contact
    @current_deal = current_deal
    @selection_context = selection_context.to_h.with_indifferent_access
  end

  def ensure_allowed!(deal, explicit_deal_id:, requested_values: [])
    latest_text = normalized_text(latest_incoming_message_text)
    return if latest_text.blank? || broad_deal_mutation_request?(latest_text)
    return if referenced_deal?(deal, latest_text)
    return if current_deal_update_without_other_deal_reference?(deal, explicit_deal_id, latest_text)
    return if explicit_deal_id && contextual_follow_up_for?(deal, latest_text, requested_values)

    raise ArgumentError, ERROR_MESSAGE
  end

  private

  attr_reader :account, :conversation, :current_contact, :current_deal, :selection_context

  def current_deal_update_without_other_deal_reference?(deal, explicit_deal_id, latest_text)
    return false if deal.id != current_deal&.id
    return false if text_references_contact_deal?(latest_text, excluding: deal)

    !explicit_deal_id || !text_references_contact_deal?(latest_text, excluding: nil)
  end

  def latest_incoming_message_text
    conversation&.messages&.incoming&.reorder(created_at: :desc, id: :desc)&.limit(1)&.pick(:content)
  end

  def contextual_follow_up_for?(deal, latest_text, requested_values)
    return false unless requested_value_referenced?(latest_text, requested_values)
    return false if text_references_contact_deal?(latest_text, excluding: deal)

    selected_deal_context_matches?(deal)
  end

  def selected_deal_context_matches?(deal)
    return false if selection_context.blank?
    return false unless selected_deal_scope == expected_deal_scope(deal)

    selected_at = Time.zone.parse(selection_context[:selected_at].to_s)
    selected_at >= SELECTION_CONTEXT_TTL.ago
  rescue ArgumentError, TypeError
    false
  end

  def selected_deal_scope
    %i[deal_id account_id conversation_id contact_id].map { |key| selection_context[key].to_i }
  end

  def expected_deal_scope(deal)
    [deal.id, account.id, conversation&.id, current_contact&.id]
  end

  def requested_value_referenced?(text, values)
    Array(values).flatten.compact_blank.any? do |value|
      normalized_value = normalized_text(value)
      next false if normalized_value.length < 2

      text.match?(/(?:\A|\s)#{Regexp.escape(normalized_value)}(?:\z|\s)/)
    end
  end

  def broad_deal_mutation_request?(text)
    all_marker = text.match?(/\b(all|every|each|both)\b/) ||
                 text.match?(/\b(все|всех|каждую|каждые|каждый|обе|оба|обеих)\b/)
    deal_marker = text.match?(/\b(deals?|records?)\b/) || text.include?('сдел')

    all_marker && deal_marker
  end

  def text_references_contact_deal?(text, excluding:)
    return false if current_contact.blank?

    contact_deals(excluding: excluding).any? { |candidate| referenced_deal?(candidate, text) }
  end

  def contact_deals(excluding:)
    scope = account.crm_deals
                   .kept
                   .joins(:deal_contacts)
                   .where(crm_deal_contacts: { contact_id: current_contact.id })
    scope = scope.where.not(id: excluding.id) if excluding.present?
    scope.limit(50)
  end

  def referenced_deal?(deal, text)
    explicit_deal_id_reference?(deal, text) || deal_title_reference?(deal, text)
  end

  def explicit_deal_id_reference?(deal, text)
    text.match?(/(?:#|id\s*|ид\s*|сделк\w*\s*)#{Regexp.escape(deal.id.to_s)}\b/)
  end

  def deal_title_reference?(deal, text)
    title_tokens = tokens(deal.title).select { |token| token.length >= 3 }
    return false if title_tokens.blank?

    text_tokens = tokens(text)
    title_tokens.any? do |title_token|
      text_tokens.any? { |text_token| matching_token?(title_token, text_token) }
    end
  end

  def normalized_text(value)
    value.to_s.downcase.tr('ё', 'е').gsub(/[^\p{Alnum}#]+/, ' ').squish
  end

  def tokens(value)
    normalized_text(value).scan(/\p{Alnum}+/)
  end

  def matching_token?(expected, actual)
    return true if expected == actual
    return false if [expected.length, actual.length].min < 5

    expected[0, 4] == actual[0, 4] || typo_token_match?(expected, actual)
  end

  def typo_token_match?(expected, actual)
    expected_stem = russian_stem(expected)
    actual_stem = russian_stem(actual)
    return false if [expected_stem.length, actual_stem.length].min < 5
    return false unless expected_stem[0] == actual_stem[0]

    single_missing_character?(expected_stem, actual_stem) || adjacent_transposition?(expected_stem, actual_stem)
  end

  def russian_stem(token)
    ending = RUSSIAN_TOKEN_ENDINGS.find { |candidate| token.end_with?(candidate) && token.length - candidate.length >= 5 }
    ending.present? ? token.delete_suffix(ending) : token
  end

  def single_missing_character?(left, right)
    shorter, longer = [left, right].sort_by(&:length)
    return false unless longer.length - shorter.length == 1

    shorter_chars = shorter.chars
    longer_chars = longer.chars
    skipped = false
    shorter_index = 0
    longer_index = 0
    while shorter_index < shorter_chars.length && longer_index < longer_chars.length
      if shorter_chars[shorter_index] == longer_chars[longer_index]
        shorter_index += 1
        longer_index += 1
        next
      end

      return false if skipped

      skipped = true
      longer_index += 1
    end

    true
  end

  def adjacent_transposition?(left, right)
    return false unless left.length == right.length

    left_chars = left.chars
    right_chars = right.chars
    mismatches = left_chars.each_index.reject { |index| left_chars[index] == right_chars[index] }
    return false unless mismatches.size == 2

    first, second = mismatches
    second == first + 1 && left_chars[first] == right_chars[second] && left_chars[second] == right_chars[first]
  end
end
