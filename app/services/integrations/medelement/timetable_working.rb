module Integrations::Medelement::TimetableWorking
  module_function

  def working?(value)
    normalize(value) == true
  end

  def normalize(value)
    return true if value.in?([true, 1, 'true', '1'])
    return false if value.in?([false, 0, 'false', '0'])
  end
end
