# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Appointments::TargetDisambiguationService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:mother_contact) { create(:contact, account: account, name: 'Алия', last_name: 'Нурланова', phone_number: '+77015551122') }
  let(:son_contact) { create(:contact, account: account, name: 'Санжар', last_name: 'Нурланов', phone_number: nil) }
  let(:conversation) { create(:conversation, account: account, contact: mother_contact) }
  let(:pediatrician) { create(:scheduling_resource, account: account, name: 'Педиатр Ибраева') }
  let(:therapist) { create(:scheduling_resource, account: account, name: 'Терапевт Омаров') }
  let(:pediatric_service) { create(:scheduling_service, account: account, name: 'Прием педиатра') }
  let(:therapy_service) { create(:scheduling_service, account: account, name: 'Прием терапевта') }

  before do
    account.enable_features!('scheduling')
  end

  describe 'fast path with 0 or 1 active upcoming appointment' do
    it 'confirms immediately with zero LLM calls when only 1 appointment exists' do
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: mother_contact,
        conversation: conversation,
        resource: therapist,
        service: therapy_service,
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 30.minutes
      )

      expect(Llm::Runtime).not_to receive(:decide)

      result = described_class.new(
        account: account,
        conversation: conversation,
        target_appointment: appointment,
        action_type: :cancel
      ).perform

      expect(result.confirmed?).to be(true)
    end
  end

  describe 'Mother and Son scenario (>= 2 active appointments on the same phone number)' do
    let!(:mother_appointment) do
      create(
        :scheduling_appointment,
        account: account,
        contact: mother_contact,
        patient_contact: mother_contact,
        conversation: conversation,
        resource: therapist,
        service: therapy_service,
        starts_at: 1.day.from_now.change(hour: 10, min: 0),
        ends_at: 1.day.from_now.change(hour: 10, min: 30)
      )
    end

    let!(:son_appointment) do
      create(
        :scheduling_appointment,
        account: account,
        contact: mother_contact,
        patient_contact: son_contact,
        conversation: conversation,
        resource: pediatrician,
        service: pediatric_service,
        starts_at: 1.day.from_now.change(hour: 15, min: 0),
        ends_at: 1.day.from_now.change(hour: 15, min: 30)
      )
    end

    it 'blocks cancellation and returns clarification list when customer says ambiguous "Я не приду"' do
      create(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                       message_type: :incoming, content: 'Здравствуйте, я завтра не приду, отмените запись')

      expect(Llm::Runtime).to receive(:decide).with(
        hash_including(feature: :appointment_disambiguation, account: account)
      ).and_return(
        Llm::OpenRouterDecisionClient::Result.new(
          choice: 'ambiguous_need_clarification',
          confidence: 0.91,
          model: 'perplexity/pplx-decider-v1.2'
        )
      )

      tool = Captain::Tools::CancelAppointmentTool.new(assistant)
      tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

      raw_result = tool.perform(tool_context, appointment_id: mother_appointment.id, patient_confirmed: true)
      payload = JSON.parse(raw_result)

      expect(payload).to include('success' => false, 'reason' => 'validation_error', 'error_class' => 'business')
      expect(mother_appointment.reload.status).to eq('scheduled')
      expect(son_appointment.reload.status).to eq('scheduled')
    end

    it 'allows cancellation of the exact target appointment when Decision model confirms with high confidence' do
      create(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                       message_type: :incoming, content: 'Сын Санжар завтра к педиатру в 15:00 не придет, отмените его прием')

      expect(Llm::Runtime).to receive(:decide).with(
        hash_including(feature: :appointment_disambiguation, account: account)
      ) do |args|
        candidates = args[:input]['candidate_appointments']
        expect(candidates.size).to eq(2)
        expect(candidates.map { |c| c['patient_name'] }).to include('Алия Нурланова', 'Санжар Нурланов')

        Llm::OpenRouterDecisionClient::Result.new(
          choice: "apt_#{son_appointment.id}",
          confidence: 0.96,
          model: 'perplexity/pplx-decider-v1.2'
        )
      end

      tool = Captain::Tools::CancelAppointmentTool.new(assistant)
      tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

      raw_result = tool.perform(tool_context, appointment_id: son_appointment.id, patient_confirmed: true)
      payload = JSON.parse(raw_result)

      expect(payload).to include('success' => true, 'appointment_id' => son_appointment.id, 'status' => 'cancelled')
      expect(son_appointment.reload.status).to eq('cancelled')
      expect(mother_appointment.reload.status).to eq('scheduled')
    end

    it 'blocks cancellation if the bot selected mother_appointment when the customer meant son_appointment' do
      create(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                       message_type: :incoming, content: 'Отмените запись сына к педиатру')

      expect(Llm::Runtime).to receive(:decide).and_return(
        Llm::OpenRouterDecisionClient::Result.new(
          choice: "apt_#{son_appointment.id}",
          confidence: 0.95,
          model: 'perplexity/pplx-decider-v1.2'
        )
      )

      result = described_class.new(
        account: account,
        conversation: conversation,
        target_appointment: mother_appointment,
        action_type: :cancel
      ).perform

      expect(result.confirmed?).to be(false)
      expect(result.choice).to eq("apt_#{son_appointment.id}")
      expect(result.clarification_error_message).to include('AMBIGUOUS_APPOINTMENT_TARGET')
    end
  end
end
