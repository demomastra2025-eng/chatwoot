module Scheduling::Constants
  APPOINTMENT_STATUSES = %w[scheduled confirmed completed cancelled no_show].freeze
  APPOINTMENT_TYPES = %w[primary secondary other].freeze
  PAYMENT_METHODS = %w[kaspi_transfer kaspi_qr cash bank_transfer card other].freeze
  PAYMENT_STATUSES = %w[awaiting_payment prepaid paid cancelled].freeze
  EXPENSE_STATUSES = %w[unpaid paid].freeze
  COMPENSATION_TYPES = %w[percent fixed].freeze
  PAYMENT_KINDS = %w[prepaid payment adjustment].freeze
  DEFAULT_TIMEZONE = 'Asia/Almaty'.freeze
  SLOT_STEP_MINUTES = 5
end
