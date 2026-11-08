# frozen_string_literal: true

class Reminders::SameDayAppointmentBatcher
  COALESCED_INTO_REMINDER_KEY = 'coalesced_into_reminder_id'
  COALESCED_DELIVERY_MESSAGE_KEY = 'coalesced_delivery_message_id'
  COALESCED_APPOINTMENT_IDS_KEY = 'coalesced_appointment_ids'
  COALESCED_REMINDER_IDS_KEY = 'coalesced_reminder_ids'

  attr_reader :reminder

  def initialize(reminder:)
    @reminder = reminder
  end

  def batchable?
    eligible_reminder? && (sibling_reminders.any? || sibling_enrollment_steps.any?)
  end

  def batched_appointments
    return [primary_appointment].compact unless batchable?

    @batched_appointments ||= begin
      ids = ([primary_appointment.id] +
             sibling_reminders.map(&:remindable_id) +
             sibling_enrollment_steps.map { |entry| entry[:enrollment].remindable_id }).uniq
      same_day_appointments.select { |apt| ids.include?(apt.id) }
    end
  end

  def decorate_content(base_content)
    return base_content if base_content.blank? || !batchable? || batched_appointments.size <= 1
    return base_content if all_times_already_present?(base_content)

    date_label = primary_appointment.starts_at.in_time_zone(time_zone).strftime('%d.%m.%Y')
    lines = batched_appointments.map { |apt| format_appointment_line(apt) }

    "#{base_content.to_s.rstrip}\n\nВсе ваши записи на #{date_label}:\n#{lines.join("\n")}"
  end

  def decorate_template_params(params)
    return params if params.blank? || !batchable? || batched_appointments.size <= 1
    return params unless params.is_a?(Hash) && params['processed_params'].present?

    primary_time = primary_appointment.starts_at.in_time_zone(time_zone).strftime('%H:%M')
    combined_times = batched_appointments.map { |apt| apt.starts_at.in_time_zone(time_zone).strftime('%H:%M') }.uniq.join(', ')
    return params if combined_times == primary_time

    updated = params.deep_dup
    updated['processed_params'] = replace_time_in_params(updated['processed_params'], primary_time, combined_times)
    updated
  end

  def coalesce!(message:)
    return if message.blank? || !batchable?

    coalesced_reminder_ids = []
    sibling_reminders.each do |sibling|
      coalesce_sibling_reminder!(sibling, message)
      coalesced_reminder_ids << sibling.id
    end

    sibling_enrollment_steps.each do |entry|
      coalesce_sibling_enrollment_step!(entry[:enrollment], entry[:step], message)
    end

    stamp_primary_reminder_metadata!(coalesced_reminder_ids)
  end

  private

  def eligible_reminder?
    reminder.persisted? &&
      reminder.action_type == 'send_message' &&
      primary_appointment.present? &&
      primary_appointment.starts_at.present? &&
      primary_appointment.status.in?(%w[scheduled confirmed])
  end

  def primary_appointment
    @primary_appointment ||= reminder.remindable if reminder.remindable.is_a?(Scheduling::Appointment)
  end

  def time_zone
    @time_zone ||= ActiveSupport::TimeZone[reminder.timezone.presence || 'Asia/Almaty'] || ActiveSupport::TimeZone['Asia/Almaty']
  end

  def same_day_range
    @same_day_range ||= primary_appointment.starts_at.in_time_zone(time_zone).all_day
  end

  def same_day_appointments
    return @same_day_appointments if defined?(@same_day_appointments)
    return @same_day_appointments = [] unless eligible_reminder?

    contact_ids = [reminder.target_contact_id, primary_appointment.contact_id, primary_appointment.patient_contact_id].compact.uniq
    conv_ids = [reminder.target_conversation_id, reminder.conversation_id, primary_appointment.conversation_id].compact.uniq

    scope = Scheduling::Appointment
            .where(account_id: reminder.account_id, status: %w[scheduled confirmed], starts_at: same_day_range)
            .includes(:resource, :service)

    scope = if contact_ids.any? && conv_ids.any?
              scope.where(
                'contact_id IN (:cids) OR patient_contact_id IN (:cids) OR conversation_id IN (:conv_ids)',
                cids: contact_ids,
                conv_ids: conv_ids
              )
            elsif contact_ids.any?
              scope.where('contact_id IN (:cids) OR patient_contact_id IN (:cids)', cids: contact_ids)
            else
              scope.where(id: primary_appointment.id)
            end

    @same_day_appointments = scope.order(:starts_at, :id).to_a
  end

  def other_same_day_appointment_ids
    @other_same_day_appointment_ids ||= same_day_appointments.map(&:id) - [primary_appointment&.id]
  end

  def sibling_reminders
    return @sibling_reminders if defined?(@sibling_reminders)
    return @sibling_reminders = [] if other_same_day_appointment_ids.empty?

    candidates = Reminder
                 .where(
                   account_id: reminder.account_id,
                   remindable_type: 'Scheduling::Appointment',
                   remindable_id: other_same_day_appointment_ids,
                   action_type: 'send_message',
                   content_kind: reminder.content_kind,
                   status: %i[draft pending processing]
                 )
                 .where.not(id: reminder.id)
                 .order(:scheduled_at, :id)
                 .to_a

    @sibling_reminders = candidates.select { |candidate| matching_sibling_reminder?(candidate) }
  end

  def matching_sibling_reminder?(candidate)
    return false if candidate.delivery_materialized?
    return false if reminder.target_contact_id.present? && candidate.target_contact_id.present? &&
                    candidate.target_contact_id != reminder.target_contact_id

    return false unless same_source_identity?(candidate)
    return false unless same_step_signature?(candidate)

    true
  end

  def same_source_identity?(candidate)
    rule_id = reminder.metadata.to_h[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY]
    cand_rule_id = candidate.metadata.to_h[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY]
    return false if rule_id.to_s != cand_rule_id.to_s
    return false if reminder.reminder_group_id != candidate.reminder_group_id

    true
  end

  def same_step_signature?(candidate)
    return current_step_key == candidate_step_key(candidate) if current_step_key.present? && candidate_step_key(candidate).present?

    if (reminder.relative? || candidate.relative?) && !(reminder.timing_mode == candidate.timing_mode &&
                          reminder.relative_anchor == candidate.relative_anchor &&
                          reminder.relative_offset_seconds.to_i == candidate.relative_offset_seconds.to_i &&
                          reminder.relative_time_mode == candidate.relative_time_mode &&
                          reminder.relative_time_of_day.to_s == candidate.relative_time_of_day.to_s)
      return false
    end

    case reminder.content_kind
    when 'channel_template'
      reminder.template_params.to_h['name'].to_s == candidate.template_params.to_h['name'].to_s
    when 'agent'
      reminder.instructions.to_s.strip == candidate.instructions.to_s.strip
    else
      reminder.body.to_s.strip == candidate.body.to_s.strip
    end
  end

  def current_step_key
    return @current_step_key if defined?(@current_step_key)

    claim_id = reminder.metadata.to_h['touch_occurrence_claim_id']
    @current_step_key = if claim_id.present?
                          TouchOccurrenceClaim.where(id: claim_id, account_id: reminder.account_id).pick(:step_key)
                        else
                          reminder.metadata.to_h['touch_occurrence_key'].to_s.split(':', 2).last.presence
                        end
  end

  def candidate_step_key(candidate)
    claim_id = candidate.metadata.to_h['touch_occurrence_claim_id']
    if claim_id.present?
      TouchOccurrenceClaim.where(id: claim_id, account_id: candidate.account_id).pick(:step_key)
    else
      candidate.metadata.to_h['touch_occurrence_key'].to_s.split(':', 2).last.presence
    end
  end

  def sibling_enrollment_steps
    return @sibling_enrollment_steps if defined?(@sibling_enrollment_steps)
    return @sibling_enrollment_steps = [] if other_same_day_appointment_ids.empty?

    enrollment_id = reminder.metadata.to_h['touch_plan_enrollment_id']
    return @sibling_enrollment_steps = [] if enrollment_id.blank? || current_step_key.blank?

    primary_enrollment = TouchPlanEnrollment.find_by(id: enrollment_id, account_id: reminder.account_id)
    return @sibling_enrollment_steps = [] if primary_enrollment.blank?

    already_covered_appointment_ids = sibling_reminders.map(&:remindable_id)
    target_appointment_ids = other_same_day_appointment_ids - already_covered_appointment_ids
    return @sibling_enrollment_steps = [] if target_appointment_ids.empty?

    enrollments = TouchPlanEnrollment
                  .active
                  .where(
                    account_id: reminder.account_id,
                    remindable_type: 'Scheduling::Appointment',
                    remindable_id: target_appointment_ids,
                    automation_rule_id: primary_enrollment.automation_rule_id,
                    source_action_id: primary_enrollment.source_action_id,
                    reminder_group_id: primary_enrollment.reminder_group_id
                  )
                  .to_a

    @sibling_enrollment_steps = enrollments.filter_map do |enrollment|
      schedule = Reminders::EnrollmentScheduleService.new(enrollment: enrollment)
      matching_step = schedule.pending_steps.find { |s| s.step_key.to_s == current_step_key.to_s }
      next if matching_step.blank?

      { enrollment: enrollment, step: matching_step }
    end
  end

  def all_times_already_present?(text)
    batched_appointments.all? do |apt|
      time_str = apt.starts_at.in_time_zone(time_zone).strftime('%H:%M')
      text.to_s.include?(time_str)
    end
  end

  def format_appointment_line(apt)
    time_str = apt.starts_at.in_time_zone(time_zone).strftime('%H:%M')
    details = [apt.resource&.name.presence, apt.service&.name.presence].compact.join(' — ')
    patient_suffix = if apt.client_name.present? && apt.client_name != primary_appointment.client_name
                       " (#{apt.client_name})"
                     else
                       ''
                     end
    details.present? ? "• #{time_str} — #{details}#{patient_suffix}" : "• #{time_str}#{patient_suffix}"
  end

  def replace_time_in_params(value, primary_time, combined_times)
    case value
    when Hash
      value.transform_values { |v| replace_time_in_params(v, primary_time, combined_times) }
    when Array
      value.map { |v| replace_time_in_params(v, primary_time, combined_times) }
    when String
      value.strip == primary_time ? combined_times : value
    else
      value
    end
  end

  def coalesce_sibling_reminder!(sibling, message)
    sibling.with_lock do
      sibling.reload
      return if sibling.delivery_materialized?
      return unless sibling.status.in?(%w[draft pending processing])

      updated_metadata = sibling.metadata.to_h.except(*Reminder::TRANSIENT_METADATA_KEYS).merge(
        COALESCED_INTO_REMINDER_KEY => reminder.id,
        COALESCED_DELIVERY_MESSAGE_KEY => message.id
      )
      sibling.send(:with_internal_metadata_write) do
        sibling.update!(
          status: :completed,
          completed_at: Time.current,
          processing_started_at: nil,
          metadata: updated_metadata
        )
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[Reminders::SameDayAppointmentBatcher] Sibling reminder coalesce skipped id=#{sibling.id}: #{e.class}: #{e.message}")
  end

  def coalesce_sibling_enrollment_step!(enrollment, step, message)
    enrollment.with_lock do
      enrollment.reload
      return unless enrollment.active?
      return if enrollment.touch_occurrence_claims.exists?(occurrence_key: step.occurrence_key)

      enrollment.touch_occurrence_claims.create!(
        account: enrollment.account,
        step_key: step.step_key,
        occurrence_key: step.occurrence_key,
        due_at: step.due_at,
        status: 'skipped',
        claimed_at: Time.current,
        last_error: 'coalesced_into_same_day_reminder',
        metadata: {
          COALESCED_INTO_REMINDER_KEY => reminder.id,
          COALESCED_DELIVERY_MESSAGE_KEY => message.id
        }
      )
      Reminders::EnrollmentScheduleService.new(enrollment: enrollment).refresh_next_due!
    end
  rescue StandardError => e
    Rails.logger.warn("[Reminders::SameDayAppointmentBatcher] Enrollment step coalesce skipped id=#{enrollment.id}: #{e.class}: #{e.message}")
  end

  def stamp_primary_reminder_metadata!(coalesced_reminder_ids)
    apt_ids = batched_appointments.map(&:id)
    updated_metadata = reminder.metadata.to_h.merge(
      COALESCED_APPOINTMENT_IDS_KEY => apt_ids,
      COALESCED_REMINDER_IDS_KEY => coalesced_reminder_ids
    )
    reminder.send(:with_internal_metadata_write) do
      reminder.update!(metadata: updated_metadata)
    end
  end
end
