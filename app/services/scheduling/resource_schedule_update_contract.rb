class Scheduling::ResourceScheduleUpdateContract
  BOOLEAN_VALUES = {
    true => true,
    false => false,
    1 => true,
    0 => false,
    '1' => true,
    '0' => false,
    'true' => true,
    'false' => false
  }.freeze
  REVISION_PATTERN = /\A[0-9a-f]{64}\z/

  attr_reader :break_rules, :expected_revision, :inherit, :work_rules

  def initialize(params)
    @inherit = parse_inherit!(required_value(params, :inherit_working_hours_from_account))
    @expected_revision = required_value(params, :expected_schedule_revision).to_s
    validate_revision!
    @work_rules = Scheduling::ResourceScheduleRulesContract.parse!(
      params,
      field: :work_rules,
      permitted: [:weekday, :start_minute, :end_minute, :active]
    )
    @break_rules = Scheduling::ResourceScheduleRulesContract.parse!(
      params,
      field: :break_rules,
      permitted: [:weekday, :start_minute, :end_minute, :title, :active]
    )
    validate_unique_weekdays!
  end

  private

  def required_value(params, field)
    raise ActionController::ParameterMissing, field unless params.key?(field)

    params[field]
  end

  def parse_inherit!(value)
    return BOOLEAN_VALUES.fetch(value) if BOOLEAN_VALUES.key?(value)

    invalid!('inherit_working_hours_from_account must be a boolean')
  end

  def validate_revision!
    return if expected_revision.match?(REVISION_PATTERN)

    invalid!('expected_schedule_revision must be a valid schedule revision')
  end

  def validate_unique_weekdays!
    weekdays = work_rules.map { |rule| rule['weekday'].to_i }
    return if weekdays.uniq.size == weekdays.size

    raise Scheduling::Error.new(
      code: 'DUPLICATE_WORKDAY',
      message: 'Only one working interval is allowed per weekday',
      status: :unprocessable_content
    )
  end

  def invalid!(message)
    raise Scheduling::Error.new(code: 'INVALID_SCHEDULE_PAYLOAD', message: message, status: :unprocessable_content)
  end
end
