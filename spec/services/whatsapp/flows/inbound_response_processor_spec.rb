require 'rails_helper'

RSpec.describe Whatsapp::Flows::InboundResponseProcessor do
  let(:account) { create(:account, limits: { non_web_inboxes: 10 }, reporting_timezone: 'Asia/Almaty') }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:inbox) { channel.inbox }
  let(:contact) do
    create(
      :contact,
      account: account,
      name: 'Марат Оспанов',
      phone_number: '+77015550101',
      custom_attributes: { 'birth_date' => '1988-05-15' }
    )
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:resource) do
    create(
      :scheduling_resource,
      account: account,
      name: 'Д-р Ерлан Ахметов',
      timezone: 'Asia/Almaty',
      slot_duration_min: 30
    )
  end
  let(:service_item) do
    create(
      :scheduling_service,
      account: account,
      name: 'УЗИ брюшной полости',
      duration_min: 30,
      base_price: 8_000
    )
  end
  let(:starts_at) { 2.days.from_now.in_time_zone('Asia/Almaty').change(hour: 10, min: 0) }
  let(:flow_token) do
    Whatsapp::Flows::TokenService.generate_flow_token(
      channel: channel,
      kind: 'booking',
      conversation_id: conversation.id,
      contact_id: contact.id,
      locale: 'ru'
    )
  end

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: starts_at.wday)
  end

  def build_flow_message(response_payload:, source_id: 'wamid.FLOW_REPLY_1', content: 'Sent')
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: contact,
      message_type: :incoming,
      source_id: source_id,
      content: content,
      content_attributes: {
        'whatsapp_flow_response' => {
          'name' => 'flow',
          'body' => content,
          'response' => response_payload
        }
      }
    )
  end

  def stub_medelement_fresh_slot!
    availability_result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
      status: 'fresh',
      slots: [{
        resource_id: resource.id,
        starts_at: starts_at.iso8601,
        ends_at: (starts_at + 30.minutes).iso8601,
        medelement_cabinet_code: 'cab-7'
      }],
      occupied_intervals: [],
      reason: nil,
      checked_at: Time.current
    )
    availability_double = instance_double(
      Integrations::Medelement::ResourceAvailabilityService,
      perform: availability_result
    )
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).and_return(availability_double)
  end

  describe '#perform' do
    it 'creates a whatsapp_flow appointment via UpsertService, unmasks asterisk-masked prefill values, and is idempotent' do
      message = build_flow_message(
        response_payload: {
          'flow_token' => flow_token, 'onelink_flow_kind' => 'booking',
          'resource_id' => resource.id.to_s, 'resource_name' => resource.name,
          'starts_at' => starts_at.iso8601, 'duration_min' => 30, 'slot_label' => '10:00–10:30',
          'client_first_name' => 'М***т', 'client_last_name' => 'О*****в',
          'client_phone' => '+7701*****01', 'client_birth_date' => '**.**.1988', 'notes' => 'Натощак'
        }
      )

      expect { described_class.new(inbox: inbox, message: message).perform }
        .to change(Scheduling::Appointment, :count).by(1)

      appointment = account.scheduling_appointments.last
      expect(appointment).to have_attributes(
        source: 'whatsapp_flow', resource_id: resource.id, service_id: nil,
        contact_id: contact.id, conversation_id: conversation.id, idempotency_key: 'wa_flow:wamid.FLOW_REPLY_1',
        client_first_name: 'Марат', client_last_name: 'Оспанов', client_phone: '+77015550101',
        client_birth_date: Date.new(1988, 5, 15), client_comment: 'Натощак'
      )

      message.reload
      expect(message.content).to include('Онлайн-запись:', resource.name)
      expect(message.content_attributes['whatsapp_flow_booking']).to include(
        'status' => 'booked', 'appointment_id' => appointment.id, 'resource_id' => resource.id
      )

      expect { described_class.new(inbox: inbox, message: message).perform }
        .not_to change(Scheduling::Appointment, :count)
    end

    it 'rejects forged or cross-contact flow tokens and records failed booking status without losing the message' do
      forged_message = build_flow_message(
        source_id: 'wamid.FORGED',
        response_payload: {
          'flow_token' => 'olf1.forged.bad_sig', 'onelink_flow_kind' => 'booking',
          'resource_id' => resource.id.to_s, 'starts_at' => starts_at.iso8601,
          'client_first_name' => 'Марат', 'client_phone' => '+77015550101'
        }
      )

      expect { described_class.new(inbox: inbox, message: forged_message).perform }
        .not_to change(Scheduling::Appointment, :count)
      expect(forged_message.reload.content_attributes['whatsapp_flow_booking']).to include(
        'status' => 'failed', 'error_code' => 'INVALID_FLOW_TOKEN'
      )

      other_contact = create(:contact, account: account, phone_number: '+77019998877')
      mismatched_token = Whatsapp::Flows::TokenService.generate_flow_token(
        channel: channel, kind: 'booking', contact_id: other_contact.id
      )
      mismatch_message = build_flow_message(
        source_id: 'wamid.MISMATCH',
        response_payload: {
          'flow_token' => mismatched_token, 'onelink_flow_kind' => 'booking',
          'resource_id' => resource.id.to_s, 'starts_at' => starts_at.iso8601,
          'client_first_name' => 'Марат', 'client_phone' => '+77015550101'
        }
      )

      expect { described_class.new(inbox: inbox, message: mismatch_message).perform }
        .not_to change(Scheduling::Appointment, :count)
      expect(mismatch_message.reload.content_attributes['whatsapp_flow_booking']).to include(
        'status' => 'failed', 'error_code' => 'FLOW_TOKEN_CONTACT_MISMATCH'
      )

      unsigned_message = build_flow_message(
        source_id: 'wamid.UNSIGNED_UNUSED',
        response_payload: {
          'flow_token' => 'unused', 'onelink_flow_kind' => 'booking',
          'resource_id' => resource.id.to_s, 'starts_at' => starts_at.iso8601,
          'client_first_name' => 'Марат', 'client_phone' => '+77015550101'
        }
      )
      expect { described_class.new(inbox: inbox, message: unsigned_message).perform }
        .not_to change(Scheduling::Appointment, :count)
      expect(unsigned_message.reload.content_attributes['whatsapp_flow_booking']).to include(
        'status' => 'failed', 'error_code' => 'INVALID_FLOW_TOKEN'
      )
    end

    it 'ignores forged client duration_min, rejects tampered booking_grant, and blocks past timestamps' do
      inflated_msg = build_flow_message(
        source_id: 'wamid.INFLATED_DUR',
        response_payload: {
          'flow_token' => flow_token, 'onelink_flow_kind' => 'booking',
          'resource_id' => resource.id.to_s, 'service_id' => service_item.id.to_s,
          'starts_at' => starts_at.iso8601, 'duration_min' => 480,
          'client_first_name' => 'Марат', 'client_phone' => '+77015550101'
        }
      )
      described_class.new(inbox: inbox, message: inflated_msg).perform
      expect(account.scheduling_appointments.find_by!(idempotency_key: 'wa_flow:wamid.INFLATED_DUR').duration_min).to eq(30)

      bad_grant_msg = build_flow_message(
        source_id: 'wamid.BAD_GRANT',
        response_payload: {
          'flow_token' => flow_token, 'booking_grant' => 'olfg1.tampered.sig', 'onelink_flow_kind' => 'booking',
          'resource_id' => resource.id.to_s, 'starts_at' => starts_at.iso8601,
          'client_first_name' => 'Марат', 'client_phone' => '+77015550101'
        }
      )
      described_class.new(inbox: inbox, message: bad_grant_msg).perform
      expect(bad_grant_msg.reload.content_attributes['whatsapp_flow_booking']).to include(
        'status' => 'failed', 'error_code' => 'INVALID_BOOKING_GRANT'
      )

      past_msg = build_flow_message(
        source_id: 'wamid.PAST_SLOT',
        response_payload: {
          'flow_token' => flow_token, 'onelink_flow_kind' => 'booking',
          'resource_id' => resource.id.to_s, 'starts_at' => 2.hours.ago.iso8601,
          'client_first_name' => 'Марат', 'client_phone' => '+77015550101'
        }
      )
      described_class.new(inbox: inbox, message: past_msg).perform
      expect(past_msg.reload.content_attributes['whatsapp_flow_booking']).to include(
        'status' => 'failed', 'error_code' => 'SLOT_OUT_OF_WINDOW'
      )
    end

    it 'records failed booking status gracefully when the slot was just taken' do
      Scheduling::Appointments::UpsertService.new(
        account: account,
        params: { resource_id: resource.id, contact_id: contact.id, starts_at: starts_at, duration_min: 30 }
      ).perform

      conflict_message = build_flow_message(
        source_id: 'wamid.CONFLICT',
        response_payload: {
          'flow_token' => flow_token, 'onelink_flow_kind' => 'booking',
          'resource_id' => resource.id.to_s, 'starts_at' => starts_at.iso8601, 'duration_min' => 30,
          'client_first_name' => 'Марат', 'client_phone' => '+77015550101'
        }
      )

      expect { described_class.new(inbox: inbox, message: conflict_message).perform }
        .not_to change(Scheduling::Appointment, :count)

      booking_meta = conflict_message.reload.content_attributes['whatsapp_flow_booking']
      expect(booking_meta['status']).to eq('failed')
      expect(booking_meta['error_code']).to be_present
    end

    it 'triggers MedElement outbound reception write when Channel::Whatsapp books a MedElement specialist' do
      account.enable_features!('medelement') if account.respond_to?(:enable_features!)
      hook_settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
      create(:integrations_hook, :medelement, account: account, settings: hook_settings)
      resource.update!(
        custom_attributes: resource.custom_attributes.merge(
          'medelement_specialist_code' => 'spec-42',
          'medelement_cabinets' => [{ 'company_cabinet_code' => 'cab-7', 'name' => 'Кабинет 7' }]
        )
      )
      service_item.update!(custom_attributes: service_item.custom_attributes.merge('medelement_nomenclature_code' => 'nom-1'))
      stub_medelement_fresh_slot!

      receipt_double = instance_double(
        Integrations::Medelement::AppointmentProviderCommandReceiptService,
        perform: true, projected_command: nil
      )
      expect(Integrations::Medelement::AppointmentProviderCommandReceiptService).to receive(:new)
        .with(hash_including(actor: channel, new_record: true))
        .and_return(receipt_double)

      med_message = build_flow_message(
        source_id: 'wamid.MED_1',
        response_payload: {
          'flow_token' => flow_token, 'onelink_flow_kind' => 'booking',
          'resource_id' => resource.id.to_s, 'service_id' => service_item.id.to_s,
          'starts_at' => starts_at.iso8601, 'duration_min' => 30, 'medelement_cabinet_code' => 'cab-7',
          'client_first_name' => 'Марат', 'client_last_name' => 'Оспанов', 'client_phone' => '+77015550101'
        }
      )

      described_class.new(inbox: inbox, message: med_message).perform

      appointment = account.scheduling_appointments.find_by!(idempotency_key: 'wa_flow:wamid.MED_1')
      expect(appointment.source).to eq('whatsapp_flow')
      expect(appointment.custom_attributes['medelement_cabinet_code']).to eq('cab-7')
      expect(appointment.custom_attributes[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY])
        .to eq(Integrations::Medelement::AppointmentProviderStatus::PENDING)
    end

    it 'processes clinic_intake Flow submissions, masks public PII with asterisks, updates Contact IIN/name, and posts a private registrar note' do
      valid_iin = '900101300047'
      msg = build_flow_message(
        source_id: 'wamid.FLOW_INTAKE_1',
        response_payload: {
          'onelink_flow_kind' => 'clinic_intake',
          'clinic_preset' => 'aliya_center',
          'request_type' => 'olymp_results',
          'client_full_name' => 'Алия Садыкова',
          'client_iin' => valid_iin,
          'visit_date' => '09.11.2026',
          'details' => 'ОАК и ферритин'
        }
      )

      result = described_class.new(inbox: inbox, message: msg).perform

      expect(result).to include(
        'status' => 'received',
        'clinic_preset' => 'aliya_center',
        'request_title' => 'Результаты КДЛ Олимп',
        'client_full_name' => 'А**я С******а',
        'client_iin' => '9001******47'
      )
      expect(msg.reload.content).to include('Заявка: Результаты КДЛ Олимп', 'ФИО: А**я С******а', 'ИИН: 9001******47')
      expect(msg.content_attributes['whatsapp_flow_intake']).to be_present
      expect(conversation.messages.where(private: true).last.content).to include('Заполнена форма пациента', 'ФИО: Алия Садыкова')
    end
  end
end
