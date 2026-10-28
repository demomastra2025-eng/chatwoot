# frozen_string_literal: true

# What a reply suggestion tells the manager about its draft, from the payload of the run (the runner flags it, see
# Captain::Assistant::AgentRunnerService#flag_draft!): a time that no scheduling read of the run found (unverified_times, see
# Captain::ReplySuggestion::DraftTimes), a time given under the name of a specialist whose own list does not hold it
# (misattributed_times, see Captain::ReplySuggestion::DraftSpecialists). The draft itself is never changed.
class Captain::ReplySuggestion::DraftTimeNotes
  def initialize(payload)
    @payload = payload.to_h.with_indifferent_access
  end

  def unverified
    Array(@payload[:unverified_times]).map(&:to_s).compact_blank
  end

  # [{ 'name' => 'Князова Жанат', 'time' => '09:00' }]: the time and the name the draft gave it.
  def misattributed
    Array(@payload[:misattributed_times]).grep(Hash).filter_map do |item|
      entry = item.with_indifferent_access
      { 'name' => entry[:name].to_s, 'time' => entry[:time].to_s } if entry[:name].present? && entry[:time].present?
    end
  end

  # The notes for the manager above the draft, in the language of the account (the job runs in it); nil when there is none.
  def note
    [unverified_note, misattributed_note].compact.join(' ').presence
  end

  # The flags for the meta of the suggestion; only the kinds there are.
  def meta
    { 'unverified_times' => unverified, 'misattributed_times' => misattributed }.compact_blank
  end

  private

  def unverified_note
    I18n.t('captain.reply_suggestion.reasons.unverified_times', times: unverified.join(', ')) if unverified.any?
  end

  def misattributed_note
    return if misattributed.empty?

    I18n.t('captain.reply_suggestion.reasons.misattributed_times',
           times: misattributed.map { |item| "#{item['time']} (#{item['name']})" }.join(', '))
  end
end
