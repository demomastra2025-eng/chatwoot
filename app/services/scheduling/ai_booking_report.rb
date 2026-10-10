class Scheduling::AiBookingReport
  DEFAULT_HOURS = 24
  MAX_HOURS = 168
  MONITOR_RULES = %w[
    A1_CREATE_PENDING A1_CREATE_CRITICAL A1_UNBOUND_PENDING
    A2_COMMAND_FAILED A2_COMMAND_DECLINED A2_COMMAND_CANCELLED
    A2_PROVIDER_UNKNOWN A2_RECONCILIATION A2_AWAITING_PATIENT
    A4_DUPLICATE A4_DOCTOR_OVERLAP A4_CABINET_OVERLAP
  ].freeze

  def initialize(hours: DEFAULT_HOURS, account_id: nil, rules: nil)
    @hours = Integer(hours)
    raise ArgumentError, 'hours must be between 1 and 168' unless @hours.between?(1, MAX_HOURS)

    @account_id = account_id.present? ? Integer(account_id) : nil
    raise ArgumentError, 'account_id must be positive' if @account_id && @account_id <= 0

    @rules = Array(rules).presence&.join(',')
  end

  def call
    connection = ActiveRecord::Base.connection
    binds = [
      bind('hours', @hours, ActiveRecord::Type::Integer.new),
      bind('account_id', @account_id, ActiveRecord::Type::Integer.new),
      bind('rules', @rules, ActiveRecord::Type::String.new)
    ]
    connection.exec_query(sql, 'AI booking report', binds).to_a
  end

  private

  def bind(name, value, type)
    ActiveRecord::Relation::QueryAttribute.new(name, value, type)
  end

  def sql
    File.read(Rails.root.join('script/onelink/ai_bookings_report.sql'))
  end
end
