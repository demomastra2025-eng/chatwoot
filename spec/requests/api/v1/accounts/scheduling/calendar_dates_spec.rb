require 'rails_helper'

RSpec.describe 'Scheduling calendar date validation', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:admin_headers) { admin.create_new_auth_token }
  let(:headers) { agent.create_new_auth_token }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
  let(:day) { Date.new(2031, 10, 14) }
  let(:calendar_path) { "/api/v1/accounts/#{account.id}/scheduling/calendar" }

  before do
    account.enable_features!('scheduling')
  end

  def body
    response.parsed_body
  end

  def calendar(**params)
    get calendar_path, params: { view: 'day', resource_ids: resource.id.to_s }.merge(params), headers: headers, as: :json
  end

  def expect_rejected(code:, field: nil)
    expect(response).to have_http_status(:unprocessable_content), response.body
    expect(body).to include('code' => code)
    expect(body).not_to have_key('payload')
    return unless field

    expect(body['error']).to include(field)
    expect(body['details']).to include('field' => field)
  end

  describe 'GET calendar' do
    it 'rejects a non-existent from date instead of showing another day' do
      ['2031-11-31', '2031-02-30', '2031-04-31', '2031-13-01', '2031-11-31T10:00:00+05:00', '2031-02-30T00:00:00Z'].each do |value|
        calendar(from: value, to: '2031-12-31T00:00:00Z')

        expect_rejected(code: 'INVALID_DATE', field: 'from')
      end
    end

    it 'rejects a non-existent to date' do
      ['2031-11-31', '2031-02-30', '2031-11-31T23:59:59Z'].each do |value|
        calendar(from: '2031-10-01T00:00:00Z', to: value)

        expect_rejected(code: 'INVALID_DATE', field: 'to')
      end
    end

    it 'rejects an impossible time of day and text that is not a date' do
      calendar(from: '2031-10-14T25:00:00Z', to: '2031-10-15T00:00:00Z')
      expect_rejected(code: 'INVALID_DATE', field: 'from')

      calendar(from: 'tomorrow', to: '2031-10-15T00:00:00Z')
      expect_rejected(code: 'INVALID_DATE', field: 'from')
    end

    it 'rejects a UTC offset that does not exist instead of reading the instant as UTC' do
      ['2031-10-14T00:00:00+25:00', '2031-10-14T00:00:00+05:99', '2031-10-14T00:00:00-24:00'].each do |value|
        calendar(from: value, to: '2031-10-15T00:00:00Z')
        expect_rejected(code: 'INVALID_DATE', field: 'from')

        calendar(from: '2031-10-14T00:00:00Z', to: value.sub('14', '15'))
        expect_rejected(code: 'INVALID_DATE', field: 'to')
      end
    end

    it 'still requires from and to' do
      calendar(to: '2031-10-15T00:00:00Z')
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include('code' => 'VALIDATION_ERROR')
      expect(body['error']).to include('from is required')
    end

    it 'rejects a reversed or empty range instead of returning an empty calendar' do
      calendar(from: '2031-10-15T00:00:00Z', to: '2031-10-14T00:00:00Z')
      expect_rejected(code: 'INVALID_DATE_RANGE', field: 'to')

      calendar(from: '2031-10-14T00:00:00Z', to: '2031-10-14T00:00:00Z')
      expect_rejected(code: 'INVALID_DATE_RANGE', field: 'to')
    end

    it 'returns the same calendar for the same instants written in UTC and with the clinic +05:00 offset' do
      create(:scheduling_work_rule, account: account, resource: resource, weekday: day.wday, start_minute: 10 * 60, end_minute: 12 * 60)
      create(:scheduling_appointment, account: account, resource: resource,
                                      starts_at: Time.find_zone('Asia/Almaty').local(2031, 10, 14, 10, 0),
                                      ends_at: Time.find_zone('Asia/Almaty').local(2031, 10, 14, 10, 30))

      calendar(from: '2031-10-13T19:00:00Z', to: '2031-10-14T19:00:00Z', include_slots: true)
      expect(response).to have_http_status(:ok), response.body
      utc_payload = body['payload']

      calendar(from: '2031-10-14T00:00:00+05:00', to: '2031-10-15T00:00:00+05:00', include_slots: true)
      expect(response).to have_http_status(:ok), response.body

      expect(body['payload']).to eq(utc_payload)
      expect(utc_payload['appointments'].size).to eq(1)
      expect(utc_payload['slots']).not_to be_empty
      expect(utc_payload.dig('range', 'from')).to start_with('2031-10-13T19:00:00')
    end

    it 'reads an unencoded +05:00 offset in the query string as the same instant instead of dropping the offset' do
      create(:scheduling_appointment, account: account, resource: resource,
                                      starts_at: Time.find_zone('Asia/Almaty').local(2031, 10, 14, 10, 0),
                                      ends_at: Time.find_zone('Asia/Almaty').local(2031, 10, 14, 10, 30))

      get "#{calendar_path}?view=day&resource_ids=#{resource.id}&from=2031-10-14T00:00:00+05:00&to=2031-10-15T00:00:00+05:00", headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(body.dig('payload', 'range')).to eq('from' => '2031-10-13T19:00:00Z', 'to' => '2031-10-14T19:00:00Z')
      expect(body.dig('payload', 'appointments').size).to eq(1)

      get "#{calendar_path}?view=day&resource_ids=#{resource.id}&from=2031-10-14T00:00:00%2B05:00&to=2031-10-15T00:00:00+05:00", headers: headers
      expect(body.dig('payload', 'range', 'from')).to eq('2031-10-13T19:00:00Z')
    end

    it 'does not move a valid date to another day' do
      calendar(from: '2031-10-30T00:00:00Z', to: '2031-10-31T00:00:00Z')

      expect(response).to have_http_status(:ok)
      expect(body.dig('payload', 'range', 'from')).to start_with('2031-10-30T00:00:00')
      expect(body.dig('payload', 'range', 'to')).to start_with('2031-10-31T00:00:00')
    end

    it 'rejects duration_min below the documented minimum of 5 instead of rounding it up' do
      [4, 0, -5, 1441, 'abc', '5.5'].each do |value|
        calendar(from: '2031-10-14T00:00:00Z', to: '2031-10-15T00:00:00Z', include_slots: true, duration_min: value)

        expect_rejected(code: 'VALIDATION_ERROR')
        expect(body['error']).to eq('duration_min must be between 5 and 1440')
      end
    end

    it 'builds slots of the requested length for an allowed duration_min and keeps the default when it is omitted' do
      create(:scheduling_work_rule, account: account, resource: resource, weekday: day.wday, start_minute: 10 * 60, end_minute: 12 * 60)

      [5, '30'].each do |value|
        calendar(from: '2031-10-13T19:00:00Z', to: '2031-10-14T19:00:00Z', include_slots: true, duration_min: value)

        expect(response).to have_http_status(:ok), response.body
        slot = body.dig('payload', 'slots').first
        expect(Time.iso8601(slot['ends_at']) - Time.iso8601(slot['starts_at'])).to eq(value.to_i.minutes)
      end

      calendar(from: '2031-10-13T19:00:00Z', to: '2031-10-14T19:00:00Z', include_slots: true, duration_min: '')
      expect(response).to have_http_status(:ok)
      expect(body.dig('payload', 'slots')).not_to be_empty
    end
  end

  describe 'GET availability' do
    let(:availability_path) { "/api/v1/accounts/#{account.id}/scheduling/availability" }

    def availability(**params)
      get availability_path, params: { resource_id: resource.id }.merge(params), headers: headers, as: :json
    end

    it 'names the failing parameter for a non-existent day' do
      availability(date: '2031-11-31')
      expect_rejected(code: 'INVALID_DATE', field: 'date')
      expect(body['error']).to include('date must be an existing calendar date')

      availability(date_from: '2031-02-30', date_to: '2031-03-01')
      expect_rejected(code: 'INVALID_DATE', field: 'date_from')
      expect(body['error']).to include('date_from must be an existing calendar date')

      availability(date_from: '2031-10-01', date_to: '2031-11-31')
      expect_rejected(code: 'INVALID_DATE', field: 'date_to')
      expect(body['error']).to include('date_to must be an existing calendar date')
    end

    it 'does not complete, reinterpret or truncate a date that is not written as YYYY-MM-DD' do
      ['2031-10', '31-10-14', '20311014', '2031-10-14T00:00:00Z', '14.10.2031'].each do |value|
        availability(date: value)
        expect_rejected(code: 'INVALID_DATE', field: 'date')

        availability(date_from: '2031-10-14', date_to: value)
        expect_rejected(code: 'INVALID_DATE', field: 'date_to')
      end
    end

    it 'rejects a reversed range and a duration below 5' do
      availability(date_from: '2031-10-15', date_to: '2031-10-14')
      expect_rejected(code: 'VALIDATION_ERROR')
      expect(body['error']).to eq('date_to must be on or after date_from')

      availability(date: '2031-10-14', duration_min: 4)
      expect_rejected(code: 'VALIDATION_ERROR')
      expect(body['error']).to eq('duration_min must be between 5 and 1440')
    end

    it 'answers an existing day' do
      create(:scheduling_work_rule, account: account, resource: resource, weekday: day.wday, start_minute: 10 * 60, end_minute: 12 * 60)

      availability(date: '2031-10-14', duration_min: 30)

      expect(response).to have_http_status(:ok), response.body
      expect(body.dig('payload', 'windows').first['starts_at']).to eq('2031-10-14T10:00:00+05:00')
    end
  end

  describe 'other date filters and writes' do
    it 'rejects a non-existent from date when listing appointments' do
      get "/api/v1/accounts/#{account.id}/scheduling/appointments", params: { from: '2031-11-31', to: '2031-12-02' },
                                                                    headers: headers, as: :json

      expect_rejected(code: 'INVALID_DATE', field: 'from')
    end

    it 'rejects a non-existent starts_at when booking and creates nothing' do
      contact = create(:contact, account: account, name: 'Patient')

      expect do
        post "/api/v1/accounts/#{account.id}/scheduling/appointments",
             params: { resource_id: resource.id, contact_id: contact.id, client_name: 'Patient', starts_at: '2031-11-31T10:00:00+05:00',
                       duration_min: 30 },
             headers: headers, as: :json
      end.not_to change(Scheduling::Appointment, :count)

      expect_rejected(code: 'INVALID_DATE', field: 'starts_at')
    end

    it 'rejects a UTC offset that does not exist when booking instead of booking the wrong hour' do
      contact = create(:contact, account: account, name: 'Patient')

      expect do
        post "/api/v1/accounts/#{account.id}/scheduling/appointments",
             params: { resource_id: resource.id, contact_id: contact.id, client_name: 'Patient', starts_at: '2031-10-14T10:00:00+25:00',
                       duration_min: 30 },
             headers: headers, as: :json
      end.not_to change(Scheduling::Appointment, :count)

      expect_rejected(code: 'INVALID_DATE', field: 'starts_at')
    end

    it 'rejects a client birth date that is not written as an existing YYYY-MM-DD day instead of guessing one' do
      contact = create(:contact, account: account, name: 'Patient')
      appointment = create(:scheduling_appointment, account: account, resource: resource, contact: contact,
                                                    client_birth_date: Date.new(1990, 5, 1))
      path = "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}"

      ['1990-05', '90-05-01', '60-05-01', '1990-02-30', '1990-05-01T00:00:00Z', '01.05.1990'].each do |value|
        patch path, params: { client_birth_date: value }, headers: headers, as: :json

        expect_rejected(code: 'VALIDATION_ERROR')
        expect(body['error']).to eq('client_birth_date must be YYYY-MM-DD')
        expect(appointment.reload.client_birth_date).to eq(Date.new(1990, 5, 1))
      end

      patch path, params: { client_birth_date: '1991-06-02' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(appointment.reload.client_birth_date).to eq(Date.new(1991, 6, 2))
    end

    it 'rejects a malformed or non-existent from and to when listing workday overrides' do
      path = "/api/v1/accounts/#{account.id}/scheduling/workday_overrides"

      %w[2031-11-31 2031-10 31-10-14].each do |value|
        get path, params: { from: value }, headers: headers, as: :json
        expect_rejected(code: 'INVALID_DATE', field: 'from')

        get path, params: { to: value }, headers: headers, as: :json
        expect_rejected(code: 'INVALID_DATE', field: 'to')
      end

      get path, params: { from: '2031-10-01', to: '2031-10-31' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok), response.body
    end

    it 'rejects a non-existent time off boundary and stores nothing' do
      path = "/api/v1/accounts/#{account.id}/scheduling/time_offs"

      expect do
        post path, params: { resource_id: resource.id, kind: 'vacation', starts_at: '2031-11-31T00:00:00Z', ends_at: '2031-12-02T00:00:00Z' },
                   headers: admin_headers, as: :json
      end.not_to change(Scheduling::TimeOff, :count)
      expect_rejected(code: 'INVALID_DATE', field: 'starts_at')

      expect do
        post path, params: { resource_id: resource.id, kind: 'vacation', starts_at: '2031-11-29T00:00:00Z', ends_at: '2031-02-30T00:00:00Z' },
                   headers: admin_headers, as: :json
      end.not_to change(Scheduling::TimeOff, :count)
      expect_rejected(code: 'INVALID_DATE', field: 'ends_at')
    end

    it 'stores a time off with existing dates exactly as sent' do
      post "/api/v1/accounts/#{account.id}/scheduling/time_offs",
           params: { resource_id: resource.id, kind: 'vacation', starts_at: '2031-11-30T00:00:00Z', ends_at: '2031-12-02T00:00:00Z' },
           headers: admin_headers, as: :json

      expect(response).to have_http_status(:created), response.body
      time_off = Scheduling::TimeOff.find(body.dig('payload', 'id'))
      expect(time_off.starts_at).to eq(Time.utc(2031, 11, 30))
      expect(time_off.ends_at).to eq(Time.utc(2031, 12, 2))
    end

    context 'with a form-encoded body and an unencoded +05:00 offset' do
      let(:form_headers) { admin_headers.merge('CONTENT_TYPE' => 'application/x-www-form-urlencoded') }

      it 'stores the instant the offset names on create, not the same clock time in UTC' do
        post "/api/v1/accounts/#{account.id}/scheduling/time_offs",
             params: "resource_id=#{resource.id}&kind=vacation&starts_at=2031-11-29T00:00:00+05:00&ends_at=2031-12-02T00:00:00+05:00",
             headers: form_headers

        expect(response).to have_http_status(:created), response.body
        time_off = Scheduling::TimeOff.find(body.dig('payload', 'id'))
        expect(time_off.starts_at).to eq(Time.utc(2031, 11, 28, 19))
        expect(time_off.ends_at).to eq(Time.utc(2031, 12, 1, 19))
      end

      it 'stores the instant the offset names on update' do
        time_off = create(:scheduling_time_off, resource: resource, starts_at: Time.utc(2031, 10, 1), ends_at: Time.utc(2031, 10, 2))

        patch "/api/v1/accounts/#{account.id}/scheduling/time_offs/#{time_off.id}",
              params: 'starts_at=2031-11-29T00:00:00+05:00&ends_at=2031-12-02T00:00:00+05:00', headers: form_headers

        expect(response).to have_http_status(:ok), response.body
        expect(time_off.reload.starts_at).to eq(Time.utc(2031, 11, 28, 19))
        expect(time_off.ends_at).to eq(Time.utc(2031, 12, 1, 19))
      end

      it 'leaves the boundaries alone when an update names neither of them' do
        time_off = create(:scheduling_time_off, resource: resource, starts_at: Time.utc(2031, 10, 1), ends_at: Time.utc(2031, 10, 2))

        patch "/api/v1/accounts/#{account.id}/scheduling/time_offs/#{time_off.id}", params: 'title=Conference', headers: form_headers

        expect(response).to have_http_status(:ok), response.body
        expect(time_off.reload).to have_attributes(title: 'Conference', starts_at: Time.utc(2031, 10, 1), ends_at: Time.utc(2031, 10, 2))
      end
    end
  end
end
