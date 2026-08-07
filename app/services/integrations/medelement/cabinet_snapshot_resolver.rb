class Integrations::Medelement::CabinetSnapshotResolver
  def initialize(account:, source_cabinets:, specialist_rows:, conflict_tracker: nil)
    @account = account
    @source_cabinets = Array(source_cabinets)
    @specialist_rows = Array(specialist_rows)
    @conflict_tracker = conflict_tracker
    @cabinets_by_code = @source_cabinets.index_by { |cabinet| cabinet_code(cabinet) }
    @conflicting_codes = detect_conflicting_codes
  end

  def cabinets_for(resource, payload)
    safe_cabinets = incoming_cabinets(payload).reject { |cabinet| conflicting?(cabinet) }
    preserved_cabinets = Array(resource.custom_attributes['medelement_cabinets']).select do |cabinet|
      conflicting?(cabinet)
    end

    (safe_cabinets + preserved_cabinets).uniq { |cabinet| cabinet_code(cabinet) }
  end

  private

  attr_reader :account, :cabinets_by_code, :conflict_tracker, :source_cabinets, :specialist_rows

  def incoming_cabinets(payload)
    return Array(payload['cabinets']).map { |cabinet| normalized_payload(cabinet) } if payload.key?('cabinets')

    Array(payload['cabinetCodes']).filter_map { |code| cabinets_by_code[code.to_s] }
  end

  def conflicting?(cabinet)
    @conflicting_codes.include?(cabinet_code(cabinet))
  end

  def detect_conflicting_codes
    names_by_code.each_with_object(Set.new) do |(code, names), result|
      next unless names.size > 1

      record_conflict(code, names.size)
      result << code
    end
  end

  def names_by_code
    cabinet_rows.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |cabinet, result|
      normalized = normalized_payload(cabinet)
      code = cabinet_code(normalized)
      name = normalized['cabinetName'].to_s.squish
      result[code] << name if code.present? && name.present?
    end
  end

  def cabinet_rows
    source_cabinets + specialist_rows.flat_map do |payload|
      Array(normalized_payload(payload)['cabinets'])
    end
  end

  def record_conflict(code, variants_count)
    conflict_tracker&.record!(
      phase: 'specialists',
      entity_type: 'cabinet',
      conflict_type: 'conflicting_cabinet_name',
      entity_key: code,
      severity: 'error',
      details: { reason: 'Provider returned multiple cabinet names', variants_count: variants_count }
    )
    Rails.logger.warn(
      "[MEDELEMENT::SPECIALISTS_SYNC] Conflicting cabinet for account=#{account.id} " \
      "entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(code)} variants=#{variants_count}"
    )
  end

  def cabinet_code(cabinet)
    normalized_payload(cabinet)['companyCabinetCode'].to_s
  end

  def normalized_payload(payload)
    payload.to_h.with_indifferent_access
  end
end
