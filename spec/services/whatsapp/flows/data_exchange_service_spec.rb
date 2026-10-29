require 'rails_helper'

RSpec.describe Whatsapp::Flows::DataExchangeService do
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
  let(:resource) do
    create(
      :scheduling_resource,
      account: account,
      name: 'Алия Серикова',
      timezone: 'Asia/Almaty',
      slot_duration_min: 30
    )
  end
  let(:service_item) do
    create(
      :scheduling_service,
      account: account,
      name: 'Первичная консультация',
      duration_min: 30,
      base_price: 10_000
    )
  end

  def sample_valid_iin
    candidate = '900101300047'
    return candidate if Scheduling::IinValidator.valid?(candidate)

    digits = '90010130001'
    weights1 = (1..11).to_a
    weights2 = [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]
    chk = digits.chars.map(&:to_i).zip(weights1).sum { |d, w| d * w } % 11
    chk = digits.chars.map(&:to_i).zip(weights2).sum { |d, w| d * w } % 11 if chk == 10
    "#{digits}#{chk}"
  end

  before do
    account.enable_features!('scheduling')
  end

  describe '#perform' do
    it 'responds to Meta health check ping with active status' do
      result = described_class.new(channel: channel, payload: { version: '3.0', action: 'ping' }).perform
      expect(result).to eq(data: { status: 'active' })
    end

    it 'acknowledges Meta client error notifications' do
      result = described_class.new(
        channel: channel,
        payload: {
          version: '3.0',
          action: 'data_exchange',
          data: { error: 'INVALID_ROUTING_MODEL', error_message: 'Client side error' }
        }
      ).perform

      expect(result).to eq(data: { acknowledged: true })
    end

    it 'returns an expired/invalid form error screen when flow_token is forged' do
      result = described_class.new(
        channel: channel,
        payload: { version: '3.0', action: 'INIT', flow_token: 'olf1.forged.bad_sig' }
      ).perform

      expect(result[:screen]).to eq('BOOKING_STEP')
      expect(result.dig(:data, :has_error)).to be(true)
      expect(result.dig(:data, :error_message)).to include('устарела')
    end

    it 'loads BOOKING_STEP on INIT and resolves SLOT_STEP with cache-only availability' do
      target_date = Time.current.in_time_zone('Asia/Almaty').to_date + 2.days
      create(:scheduling_work_rule, resource: resource, weekday: target_date.wday)
      service_item
      flow_token = Whatsapp::Flows::TokenService.generate_flow_token(channel: channel, kind: 'booking', locale: 'ru')

      init_res = described_class.new(
        channel: channel,
        payload: { version: '3.0', action: 'INIT', flow_token: flow_token }
      ).perform

      expect(init_res[:screen]).to eq('BOOKING_STEP')
      expect(init_res.dig(:data, :show_services)).to be(true)
      expect(init_res.dig(:data, :services).map { |s| s[:id] }).to include(service_item.id.to_s)
      expect(init_res.dig(:data, :specialists).map { |s| s[:id] }).to include(resource.id.to_s)

      expect(Scheduling::ScheduleDayAvailabilityService).to receive(:new)
        .with(hash_including(resource: resource, allow_live: false))
        .and_call_original

      slot_res = described_class.new(
        channel: channel,
        payload: {
          version: '3.0', action: 'data_exchange', screen: 'BOOKING_STEP', flow_token: flow_token,
          data: {
            step: 'BOOKING_STEP', service_id: service_item.id.to_s,
            resource_id: resource.id.to_s, booking_date: target_date.iso8601
          }
        }
      ).perform

      expect(slot_res[:screen]).to eq('SLOT_STEP')
      expect(slot_res.dig(:data, :slots, 0, :id)).to start_with("#{resource.id}@")
    end

    it 'prefills DETAILS_STEP only for verified signed flow tokens and never for unsigned preview tokens' do
      target_date = Time.current.in_time_zone('Asia/Almaty').to_date + 2.days
      create(:scheduling_work_rule, resource: resource, weekday: target_date.wday)
      contact = create(:contact, account: account, name: 'Айгуль Касымова', phone_number: '+77015551234')
      flow_token = Whatsapp::Flows::TokenService.generate_flow_token(
        channel: channel, kind: 'booking', contact_id: contact.id, locale: 'ru'
      )
      slot_key = Whatsapp::Flows::BookingSlotResolver.new(account: account)
                                                     .slots_for_date(resources: [resource], date: target_date, service: service_item)
                                                     .first[:key]
      step_data = {
        step: 'SLOT_STEP', service_id: service_item.id.to_s,
        resource_id: resource.id.to_s, booking_date: target_date.iso8601, slot_key: slot_key
      }

      verified_res = described_class.new(
        channel: channel,
        payload: { version: '3.0', action: 'data_exchange', screen: 'SLOT_STEP', flow_token: flow_token, data: step_data }
      ).perform
      expect(verified_res[:screen]).to eq('DETAILS_STEP')
      expect(verified_res[:data]).to include(
        init_first_name: 'Айгуль', init_last_name: 'Касымова', init_phone: '+77015551234', selected_slot_key: slot_key
      )

      preview_res = described_class.new(
        channel: channel,
        payload: { version: '3.0', action: 'data_exchange', screen: 'SLOT_STEP', flow_token: 'flows-builder-preview', data: step_data }
      ).perform
      expect(preview_res.dig(:data, :init_phone)).to eq('')
    end

    it 'validates CONFIRM_BOOKING inputs and returns SUCCESS extension_message_response params' do
      target_date = Time.current.in_time_zone('Asia/Almaty').to_date + 2.days
      create(:scheduling_work_rule, resource: resource, weekday: target_date.wday)
      valid_iin = sample_valid_iin
      flow_token = Whatsapp::Flows::TokenService.generate_flow_token(channel: channel, kind: 'booking', locale: 'ru')
      slot_key = Whatsapp::Flows::BookingSlotResolver.new(account: account)
                                                     .slots_for_date(resources: [resource], date: target_date, service: service_item)
                                                     .first[:key]
      base_submission = {
        step: 'CONFIRM_BOOKING', service_id: service_item.id.to_s, resource_id: resource.id.to_s,
        booking_date: target_date.iso8601, slot_key: slot_key,
        client_first_name: 'Айгуль', client_last_name: 'Касымова', client_phone: '+77015551234'
      }

      bad_iin_res = described_class.new(
        channel: channel,
        payload: {
          version: '3.0', action: 'data_exchange', screen: 'DETAILS_STEP', flow_token: flow_token,
          data: base_submission.merge(client_iin: '123456789012')
        }
      ).perform
      expect(bad_iin_res[:screen]).to eq('DETAILS_STEP')
      expect(bad_iin_res.dig(:data, :has_error)).to be(true)

      confirm_res = described_class.new(
        channel: channel,
        payload: {
          version: '3.0', action: 'data_exchange', screen: 'DETAILS_STEP', flow_token: flow_token,
          data: base_submission.merge(client_birth_date: '01.01.1990', client_iin: valid_iin, notes: 'Позвонить за час')
        }
      ).perform
      expect(confirm_res[:screen]).to eq('SUCCESS')
      completion_params = confirm_res.dig(:data, :extension_message_response, :params)
      expect(completion_params).to include(
        flow_token: flow_token, onelink_flow_kind: 'booking', resource_id: resource.id.to_s,
        service_id: service_item.id.to_s, client_birth_date: '1990-01-01', client_iin: valid_iin, notes: 'Позвонить за час'
      )
      expect(completion_params[:booking_grant]).to start_with('olfg1.')
    end

    it 'suggests the nearest available date when chosen date has no free slots' do
      empty_date = Time.current.in_time_zone('Asia/Almaty').to_date + 1.day
      available_date = empty_date + 1.day
      create(:scheduling_work_rule, resource: resource, weekday: available_date.wday)
      flow_token = Whatsapp::Flows::TokenService.generate_flow_token(channel: channel, locale: 'ru')

      res = described_class.new(
        channel: channel,
        payload: {
          version: '3.0', action: 'data_exchange', screen: 'BOOKING_STEP', flow_token: flow_token,
          data: { step: 'BOOKING_STEP', service_id: 'none', resource_id: resource.id.to_s, booking_date: empty_date.iso8601 }
        }
      ).perform

      expect(res[:screen]).to eq('BOOKING_STEP')
      expect(res.dig(:data, :has_error)).to be(true)
      expect(res.dig(:data, :init_booking_date)).to eq(available_date.iso8601)
    end
  end
end
