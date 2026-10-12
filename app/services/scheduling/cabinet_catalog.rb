# Cabinets of an account. MedElement keeps them on the specialists
# (scheduling_resources.custom_attributes['medelement_cabinets']) and stamps the chosen code on
# an appointment (scheduling_appointments.custom_attributes['medelement_cabinet_code']).
class Scheduling::CabinetCatalog
  APPOINTMENT_CODE_SQL = "custom_attributes ->> 'medelement_cabinet_code'".freeze
  DETAIL_KEYS = %i[name number type].freeze

  def initialize(account:)
    @account = account
  end

  # One entry per cabinet code, sorted by name: [{ code:, name:, number:, type: }].
  def cabinets
    @cabinets ||= cabinet_payloads.group_by { |payload| payload[:code] }
                                  .map { |code, variants| merge_variants(code, variants) }
                                  .sort_by { |cabinet| sort_key(cabinet) }
  end

  def codes
    cabinets.pluck(:code)
  end

  # A cabinet is known when an available specialist has it or an appointment of the account
  # already carries its code (so a rule keeps saving after the specialist is archived).
  def all_known?(candidate_codes)
    requested = Array.wrap(candidate_codes).map(&:to_s).uniq
    return false if requested.empty?

    unresolved = requested - codes
    return true if unresolved.empty?

    (unresolved - appointment_codes_among(unresolved)).empty?
  end

  private

  attr_reader :account

  def cabinet_payloads
    account.scheduling_resources.available_for_scheduling.order(:id).pluck(:custom_attributes).flat_map do |attributes|
      Array.wrap(attributes.to_h['medelement_cabinets']).filter_map { |payload| cabinet_payload(payload) }
    end
  end

  def cabinet_payload(payload)
    return unless payload.is_a?(Hash)

    code = Integrations::Medelement::CabinetAttributes.code(payload)
    return if code.blank?

    {
      code: code,
      name: Integrations::Medelement::CabinetAttributes.cabinet_name(payload),
      number: Integrations::Medelement::CabinetAttributes.cabinet_number(payload),
      type: Integrations::Medelement::CabinetAttributes.cabinet_type(payload)
    }
  end

  # Specialists may describe the same cabinet differently: keep the first non-blank value of each detail.
  def merge_variants(code, variants)
    details = DETAIL_KEYS.index_with { |key| variants.filter_map { |variant| variant[key] }.first }
    { code: code, **details }
  end

  def appointment_codes_among(requested_codes)
    account.scheduling_appointments
           .where("#{APPOINTMENT_CODE_SQL} IN (?)", requested_codes)
           .distinct
           .pluck(Arel.sql(APPOINTMENT_CODE_SQL))
  end

  # "Кабинет 2" sorts before "Кабинет 10".
  def sort_key(cabinet)
    label = cabinet[:name].presence || cabinet[:number].presence || cabinet[:code]
    natural_key = label.downcase.scan(/\d+|\D+/).map { |part| part.match?(/\A\d/) ? [0, part.to_i, ''] : [1, 0, part] }

    [natural_key, cabinet[:number].to_s, cabinet[:code]]
  end
end
