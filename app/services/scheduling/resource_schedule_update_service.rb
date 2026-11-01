class Scheduling::ResourceScheduleUpdateService
  UNSPECIFIED_RULES = Object.new.freeze
  INTEGER_FIELDS = %w[weekday start_minute end_minute].freeze
  WORK_RULE_FIELDS = (INTEGER_FIELDS + %w[active]).freeze
  BREAK_RULE_FIELDS = (WORK_RULE_FIELDS + %w[title]).freeze
  BOOLEAN_STRINGS = { '1' => true, 't' => true, 'true' => true, 'on' => true,
                      '0' => false, 'f' => false, 'false' => false, 'off' => false }.freeze
  private_constant :UNSPECIFIED_RULES

  def initialize(resource:)
    @resource = resource
  end

  # Optional rule sets share the resource transaction. Omitting a set preserves it;
  # an explicit empty array clears it, as in the existing standalone rules APIs.
  def update!(attributes: {}, work_rules: UNSPECIFIED_RULES, break_rules: UNSPECIFIED_RULES)
    @resource.with_lock do
      ensure_available_resource!(work_rules, break_rules)
      work_rules = normalize_rule_set(work_rules, :work_rules)
      break_rules = normalize_rule_set(break_rules, :break_rules)
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

  def ensure_available_resource!(work_rules, break_rules)
    return if work_rules.equal?(UNSPECIFIED_RULES) && break_rules.equal?(UNSPECIFIED_RULES)

    raise ActiveRecord::RecordNotFound, 'Specialist not found' if @resource.deleted_from_scheduling?
  end

  def normalize_rule_set(rules, association)
    return nil if rules.equal?(UNSPECIFIED_RULES)

    raise ArgumentError, "#{association} must be an array" unless rules.is_a?(Array)

    rules.each_with_index.map { |rule, index| normalize_rule(rule, association, index) }
  end

  def normalize_rule(rule, association, index)
    raw = rule.is_a?(ActionController::Parameters) ? rule.to_unsafe_h : rule
    raise ArgumentError, "#{association}[#{index}] must be an object" unless raw.is_a?(Hash)

    allowed_fields = association == :work_rules ? WORK_RULE_FIELDS : BREAK_RULE_FIELDS
    attrs = raw.stringify_keys.slice(*allowed_fields)
    INTEGER_FIELDS.each do |field|
      attrs[field] = Scheduling::IntegerNumericNormalizer.normalize(attrs[field], field_name: "#{association}[#{index}].#{field}")
    end
    attrs['active'] = normalize_active(attrs['active']) if attrs.key?('active')
    validate_title!(attrs['title'])
    attrs
  end

  def normalize_active(value)
    normalized =
      case value
      when true, false then value
      when Integer then value == 1 if [0, 1].include?(value)
      when String then BOOLEAN_STRINGS[value.strip.downcase]
      end
    return normalized unless normalized.nil?

    raise ArgumentError, 'active must be a boolean'
  end

  def validate_title!(title)
    return if title.nil? || title.is_a?(String)

    raise ArgumentError, 'title must be a string'
  end

  def validate_rules!(work_rules, break_rules)
    if @resource.inherit_working_hours_from_account?
      ensure_not_inherited!('WORK_RULES_INHERITED') unless work_rules.nil?
      ensure_not_inherited!('BREAK_RULES_INHERITED') unless break_rules.nil?
    end
    return if work_rules.nil?

    weekdays = work_rules.pluck('weekday')
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
