module Integrations::Medelement::CabinetAttributes
  CODE_KEYS = %w[companyCabinetCode company_cabinet_code COMPANY_CABINET_CODE].freeze

  module_function

  def code(payload)
    attributes = payload.to_h
    CODE_KEYS.filter_map { |key| attributes[key].presence }.first&.to_s
  end
end
