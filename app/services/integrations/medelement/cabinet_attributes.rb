module Integrations::Medelement::CabinetAttributes
  CODE_KEYS = %w[companyCabinetCode company_cabinet_code COMPANY_CABINET_CODE].freeze
  NAME_KEYS = %w[cabinetName cabinet_name companyCabinetName company_cabinet_name].freeze
  NUMBER_KEYS = %w[cabinetNumber cabinet_number].freeze
  TYPE_KEYS = %w[cabinetType cabinet_type].freeze

  module_function

  def code(payload)
    first_present(payload, CODE_KEYS)
  end

  # Not named `name`: module_function would shadow Module#name on this module.
  def cabinet_name(payload)
    first_present(payload, NAME_KEYS)
  end

  def cabinet_number(payload)
    first_present(payload, NUMBER_KEYS)
  end

  def cabinet_type(payload)
    first_present(payload, TYPE_KEYS)
  end

  def first_present(payload, keys)
    attributes = payload.to_h
    keys.filter_map { |key| attributes[key].presence }.first&.to_s
  end
end
