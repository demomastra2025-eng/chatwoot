class Scheduling::ResourceScheduleUpdateService
  def initialize(resource:)
    @resource = resource
  end

  # Optional rule sets share the resource transaction. Omitting a set preserves it;
  # an explicit empty array clears it, as in the existing standalone rules APIs.
  def update!(attributes: {}, work_rules: nil, break_rules: nil)
    @resource.with_lock do
      if @resource.deleted_from_scheduling? && (!work_rules.nil? || !break_rules.nil?)
        raise ActiveRecord::RecordNotFound, 'Specialist not found'
      end

      was_inheriting = @resource.inherit_working_hours_from_account?
      @resource.assign_attributes(attributes)
      validate_rules!(work_rules, break_rules)
      @resource.save!
      @resource.use_personal_working_hours! if was_inheriting && !@resource.inherit_working_hours_from_account?
      @resource.apply_workspace_working_hours! if @resource.inherit_working_hours_from_account?
      replace_rules!(:work_rules, work_rules) unless work_rules.nil?
      replace_rules!(:break_rules, break_rules) unless break_rules.nil?
    end
    @resource
  end

  private

  def validate_rules!(work_rules, break_rules)
    if @resource.inherit_working_hours_from_account?
      ensure_not_inherited!('WORK_RULES_INHERITED') unless work_rules.nil?
      ensure_not_inherited!('BREAK_RULES_INHERITED') unless break_rules.nil?
    end
    return if work_rules.nil?

    weekdays = work_rules.map { |rule| Scheduling::WorkRule.new(rule.to_h).weekday }
    return if weekdays.uniq.size == weekdays.size

    raise Scheduling::Error.new(code: 'DUPLICATE_WORK_WEEKDAY', message: 'Each working weekday can only appear once',
                                status: :unprocessable_content)
  end

  def ensure_not_inherited!(code)
    subject = code == 'BREAK_RULES_INHERITED' ? 'breaks' : 'hours'
    raise Scheduling::Error.new(code: code, message: "Disable workspace schedule inheritance before editing specialist #{subject}",
                                status: :unprocessable_content)
  end

  def replace_rules!(association, rules)
    @resource.public_send(association).destroy_all
    rules.each { |rule| @resource.public_send(association).create!(rule.to_h) }
  end
end
