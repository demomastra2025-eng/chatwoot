module Integrations::Medelement::WorkingFlag
  module_function

  def working?(value)
    return true if value == true || value == 1

    value.is_a?(String) && %w[true 1].include?(value.strip.downcase)
  end
end
