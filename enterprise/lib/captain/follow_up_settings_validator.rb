# frozen_string_literal: true

class Captain::FollowUpSettingsValidator
  TIME_FORMAT = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/
  LANGUAGES = %w[ru kk en].freeze

  def initialize(assistant:)
    @assistant = assistant
  end

  def errors
    @errors ||= validate
  end

  private

  attr_reader :assistant

  def validate
    settings = assistant.config.to_h.deep_stringify_keys['follow_up_settings']
    return [] if settings.nil?
    return ['follow_up_settings must be an object'] unless settings.is_a?(Hash)

    errors = []
    validate_quiet_hours(settings['quiet_hours'], errors)
    validate_steps(settings, errors)
    errors
  end

  def validate_quiet_hours(quiet_hours, errors)
    return if quiet_hours.nil?
    return errors << 'quiet_hours must be an object' unless quiet_hours.is_a?(Hash)
    errors << 'quiet_hours enabled must be a boolean' if quiet_hours.key?('enabled') && [true, false].exclude?(quiet_hours['enabled'])
    return if quiet_hours['enabled'] == false

    start_time = quiet_hours['start_time'].to_s
    end_time = quiet_hours['end_time'].to_s
    timezone = quiet_hours['timezone'].to_s
    errors << 'quiet_hours start_time is invalid' if quiet_hours.key?('start_time') && !TIME_FORMAT.match?(start_time)
    errors << 'quiet_hours end_time is invalid' if quiet_hours.key?('end_time') && !TIME_FORMAT.match?(end_time)
    if quiet_hours.key?('start_time') && quiet_hours.key?('end_time') && start_time == end_time
      errors << 'quiet_hours start_time and end_time must differ'
    end
    if quiet_hours.key?('timezone') && !TZInfo::Timezone.all_identifiers.include?(timezone)
      errors << 'quiet_hours timezone is invalid'
    end
  end

  def validate_steps(settings, errors)
    steps = settings['steps']
    return if steps.nil? && settings['enabled'] != true
    return errors << 'follow_up steps must be an array' unless steps.is_a?(Array)

    errors << 'follow_up steps must contain between 1 and 5 steps' if settings['enabled'] == true && !steps.length.between?(1, 5)
    steps.first(5).each_with_index do |step, index|
      validate_step(step, index, errors)
    end
  end

  def validate_step(step, index, errors)
    return errors << "follow_up step #{index + 1} must be an object" unless step.is_a?(Hash)

    normalized = step.deep_stringify_keys
    delay = Integer(normalized['delay_seconds'].to_s, exception: false)
    errors << "follow_up step #{index + 1} delay_seconds must be positive" unless delay&.positive?
    validate_inbox_variants(normalized['template_variants_by_inbox'], index, errors)
    global_variants = normalized['template_variants']
    return if global_variants.nil?
    return errors << "follow_up step #{index + 1} template variants must be an object" unless global_variants.is_a?(Hash)

    assistant.inboxes.where(channel_type: 'Channel::Whatsapp').find_each do |inbox|
      overrides = normalized.fetch('template_variants_by_inbox', {})
      overrides = overrides.is_a?(Hash) ? overrides.fetch(inbox.id.to_s, {}) : {}
      fallback = global_variants.except(*(overrides.is_a?(Hash) ? overrides.select { |_language, params| params.present? }.keys : []))
      validate_variants(inbox, fallback, index, errors) if fallback.present?
    end
  end

  def validate_inbox_variants(variants_by_inbox, step_index, errors)
    return if variants_by_inbox.nil?
    return errors << "follow_up step #{step_index + 1} template_variants_by_inbox must be an object" unless variants_by_inbox.is_a?(Hash)

    variants_by_inbox.each do |inbox_id, variants|
      inbox = assistant.inboxes.find_by(id: inbox_id)
      next if inbox.blank?

      validate_variants(inbox, variants, step_index, errors)
    end
  end

  def validate_variants(inbox, variants, step_index, errors)
    unless variants.is_a?(Hash)
      errors << "follow_up step #{step_index + 1} template variants must be an object"
      return
    end

    variants.deep_stringify_keys.each do |language, params|
      unless LANGUAGES.include?(language) && params.is_a?(Hash)
        errors << "follow_up step #{step_index + 1} has an invalid template language"
        next
      end
      unless params['language'].to_s.split(/[-_]/).first == language
        errors << "follow_up step #{step_index + 1} #{language}: template language does not match variant"
        next
      end

      begin
        Campaigns::TemplateParamsValidator.validate!(inbox: inbox, template_params: params)
      rescue ArgumentError => e
        errors << "follow_up step #{step_index + 1} #{language}: #{e.message}"
      end
    end
  end
end
