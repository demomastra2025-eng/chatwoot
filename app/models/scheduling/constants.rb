module Scheduling::Constants
  APPOINTMENT_STATUSES = %w[scheduled confirmed completed cancelled no_show].freeze
  APPOINTMENT_TYPES = %w[primary secondary other].freeze
  PAYMENT_STATUSES = %w[awaiting_payment prepaid paid cancelled].freeze
  DEFAULT_TIMEZONE = 'Asia/Almaty'.freeze
  SLOT_STEP_MINUTES = 5
end
