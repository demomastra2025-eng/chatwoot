# frozen_string_literal: true

module Captain
  module Appointments
    class TargetDisambiguationService
      CONFIDENCE_THRESHOLD = 0.85
      AMBIGUOUS_CHOICE = 'ambiguous_need_clarification'
      ALL_APPOINTMENTS_CHOICE = 'all_appointments'

      Result = Struct.new(:confirmed, :choice, :confidence, :candidates, :clarification_message, keyword_init: true) do
        def confirmed?
          confirmed == true
        end

        def clarification_error_message
          clarification_message
        end
      end

      def initialize(account:, conversation:, target_appointment:, action_type: :cancel, action: nil, **_extra)
        @account = account
        @conversation = conversation
        @target_appointment = target_appointment
        @action_type = (action || action_type || :cancel).to_sym
      end

      def perform
        return Result.new(confirmed: true, candidates: []) if conversation.blank? || target_appointment.blank?

        candidates = active_upcoming_candidates
        return Result.new(confirmed: true, candidates: candidates) if candidates.size < 2
        return Result.new(confirmed: true, candidates: candidates) unless incoming_customer_messages_exist?

        decision = request_decision(candidates)
        return Result.new(confirmed: true, candidates: candidates) if decision.nil?

        expected_key = "apt_#{target_appointment.id}"
        matched = (decision.choice == expected_key || decision.choice == ALL_APPOINTMENTS_CHOICE) &&
                  (decision.confidence.nil? || decision.confidence >= CONFIDENCE_THRESHOLD)

        if matched
          Result.new(
            confirmed: true,
            choice: decision.choice,
            confidence: decision.confidence,
            candidates: candidates
          )
        else
          Result.new(
            confirmed: false,
            choice: decision.choice,
            confidence: decision.confidence,
            candidates: candidates,
            clarification_message: build_clarification_message(candidates)
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[Captain::Appointments::TargetDisambiguationService] Decision failed: #{e.class}: #{e.message}")
        Result.new(confirmed: true, candidates: candidates || [])
      end

      private

      attr_reader :account, :conversation, :target_appointment, :action_type

      def incoming_customer_messages_exist?
        conversation.messages.where(private: false, message_type: :incoming).exists?
      end

      def active_upcoming_candidates
        contact_id = conversation.contact_id || target_appointment.contact_id
        base_scope = account.scheduling_appointments.active_statuses.where('starts_at >= ?', 2.hours.ago)
        scoped = if contact_id.present?
                   base_scope.where(contact_id: contact_id)
                             .or(base_scope.where(patient_contact_id: contact_id))
                             .or(base_scope.where(conversation_id: conversation.id))
                 else
                   base_scope.where(conversation_id: conversation.id)
                 end
        scoped.includes(:resource, :service, :contact, :patient_contact).order(:starts_at, :id).limit(8).to_a
      end

      def request_decision(candidates)
        model = ::Llm::Config.model_for(
          feature: 'appointment_disambiguation',
          account: account,
          fallback: 'perplexity/pplx-decider-v1.2'
        ).presence || 'perplexity/pplx-decider-v1.2'
        return nil unless ::Llm::OpenRouterDecisionClient.supported_model?(model)

        ::Llm::Runtime.decide(
          feature: :appointment_disambiguation,
          account: account,
          model: model,
          input: build_state(candidates),
          options: {
            decision_criteria: build_criteria(candidates),
            decision_instructions: build_instructions
          }
        )
      end

      def build_state(candidates)
        now = Time.current.in_time_zone(account_timezone)
        {
          'requested_action' => action_type.to_s,
          'current_local_time' => now.strftime('%Y-%m-%d %H:%M'),
          'proposed_target_appointment_id' => "apt_#{target_appointment.id}",
          'candidate_appointments' => candidates.map { |apt| serialize_appointment(apt, now) },
          'last_outbound_touch' => last_outbound_touch_text,
          'recent_messages' => recent_messages_payload
        }
      end

      def serialize_appointment(apt, now)
        patient = apt.patient_contact || apt.contact
        local_start = apt.starts_at&.in_time_zone(account_timezone)
        hours_until = local_start ? ((local_start - now) / 3600.0).round(1) : nil
        {
          'key' => "apt_#{apt.id}",
          'appointment_id' => apt.id,
          'patient_name' => [patient&.name, patient&.try(:last_name)].map { |v| v.to_s.strip }.reject(&:empty?).join(' ').presence || 'Unknown',
          'patient_birth_date' => patient&.custom_attributes.to_h['birth_date'] || patient&.custom_attributes.to_h['date_of_birth'],
          'is_separate_patient' => apt.patient_contact_id.present? && apt.patient_contact_id != apt.contact_id,
          'specialist' => apt.resource&.name.to_s,
          'service' => apt.service&.name.to_s,
          'local_date' => local_start&.strftime('%Y-%m-%d'),
          'local_time' => local_start&.strftime('%H:%M'),
          'hours_until_visit' => hours_until,
          'status' => apt.status
        }.compact
      end

      def last_outbound_touch_text
        msg = conversation.messages
                          .where(private: false, message_type: %i[outgoing template])
                          .order(id: :desc)
                          .first
        msg&.content.to_s.squish.truncate(500).presence
      end

      def recent_messages_payload
        conversation.messages
                    .where(private: false)
                    .where.not(content: [nil, ''])
                    .order(id: :desc)
                    .limit(10)
                    .reverse
                    .map do |m|
          {
            'role' => m.incoming? ? 'customer' : 'clinic',
            'text' => m.content.to_s.squish.truncate(400)
          }
        end
      end

      def build_criteria(candidates)
        criteria = {}
        candidates.each do |apt|
          patient = apt.patient_contact || apt.contact
          local_start = apt.starts_at&.in_time_zone(account_timezone)
          summary = [
            [patient&.name, patient&.try(:last_name)].map { |v| v.to_s.strip }.reject(&:empty?).join(' ').presence,
            apt.resource&.name.to_s.strip.presence,
            apt.service&.name.to_s.strip.presence,
            local_start&.strftime('%d.%m %H:%M')
          ].compact.join(' — ')
          criteria["apt_#{apt.id}"] = "The customer clearly intends to #{action_type} strictly this appointment: #{summary}."
        end
        criteria[ALL_APPOINTMENTS_CHOICE] = "The customer explicitly asked to #{action_type} ALL of their upcoming appointments at once."
        criteria[AMBIGUOUS_CHOICE] =
          'The customer message is ambiguous (e.g. just "I will not come" / "Cancel") and does not clearly identify which of the multiple appointments or patients is meant.'
        criteria
      end

      def build_instructions
        'Determine which specific upcoming appointment the customer intends to cancel or reschedule based on patient name/role (e.g. mother vs child), doctor/specialty, service, date/time, or the immediately preceding clinic reminder. If there are multiple appointments and the customer has not clearly disambiguated which one they mean, choose ambiguous_need_clarification.'
      end

      def build_clarification_message(candidates)
        items = candidates.map do |apt|
          patient = apt.patient_contact || apt.contact
          local_start = apt.starts_at&.in_time_zone(account_timezone)
          "ID #{apt.id}: #{patient&.name || 'Пациент'} — #{apt.resource&.name || apt.service&.name || 'Прием'} (#{local_start&.strftime('%d.%m в %H:%M')})"
        end.join('; ')
        "AMBIGUOUS_APPOINTMENT_TARGET: Multiple active appointments exist on this contact (#{items}). Ask the customer to clarify which specific appointment (patient, doctor, or time) they want to #{action_type} before calling this tool."
      end

      def account_timezone
        account.try(:timezone).presence || 'Asia/Almaty'
      end
    end
  end
end
