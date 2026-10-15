require 'administrate/field/base'
require 'bigdecimal'

# The limit overrides of a clinic (Account#limits): one input per limit on the form. The Russian name and hint of every
# limit live in super_admin.limits.<key>.{label,hint}; a blank input means «use the default».
class AccountLimitsField < Administrate::Field::Base
  STORAGE_GB_IN_BYTES = 1.gigabyte

  # key => how the input behaves. `bytes` limits are typed in gigabytes (decimals allowed).
  LIMIT_DEFINITIONS = {
    agents: {},
    inboxes: {},
    conversations: {},
    non_web_inboxes: {},
    storage_bytes: { bytes: true, step: '0.1' },
    captain_responses: {},
    captain_documents: {},
    captain_tokens: {},
    emails: {}
  }.freeze

  def rows
    overrides = normalized_overrides

    LIMIT_DEFINITIONS.map do |key, meta|
      meta.merge(
        key: key,
        label: label_for(key),
        hint: I18n.t("super_admin.limits.#{key}.hint"),
        input_id: "account_limits_#{key}",
        value: normalize_value(key, overrides[key])
      )
    end
  end

  def to_s
    configured_rows.map { |row| "#{row[:label]}: #{formatted_value(row)}" }.join(', ')
  end

  private

  # The input of the storage limit says that it takes gigabytes
  def label_for(key)
    I18n.t("super_admin.limits.#{key}.input_label", default: I18n.t("super_admin.limits.#{key}.label"))
  end

  def configured_rows
    # 0 counts: a limit of 0 is a value (forbidden), not a blank
    rows.select { |row| row[:value].present? }
  end

  def normalized_overrides
    (data.presence || {}).to_h.deep_symbolize_keys
  end

  def normalize_value(key, value)
    return if value.blank?
    return bytes_to_gb(value) if key == :storage_bytes
    return Integer(value, 10) if value.is_a?(String) && value.match?(/\A\d+\z/)

    value
  end

  def formatted_value(row)
    return "#{ActiveSupport::NumberHelper.number_to_rounded(row[:value].to_f, precision: 2, strip_insignificant_zeros: true)} ГБ" if row[:bytes]

    row[:value]
  end

  def bytes_to_gb(value)
    (BigDecimal(value.to_s) / STORAGE_GB_IN_BYTES).to_f
  rescue ArgumentError
    value
  end
end
