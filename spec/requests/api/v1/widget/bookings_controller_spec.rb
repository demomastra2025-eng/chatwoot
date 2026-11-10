# frozen_string_literal: true

require 'rails_helper'

RSpec.describe '/api/v1/widget/booking', type: :request do
  let(:account) { create(:account, name: 'МО "Әлия"', reporting_timezone: 'Asia/Almaty') }
  let(:web_widget) { create(:channel_widget, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Алия Нурланова', phone_number: '+77015551122') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: web_widget.inbox) }
  let(:payload) { { source_id: contact_inbox.source_id, inbox_id: web_widget.inbox.id } }
  let(:token) { Widget::TokenService.new(payload: payload).generate_token }
  let(:headers) { { 'X-Auth-Token' => token } }

  let!(:resource) do
    create(
      :scheduling_resource,
      account: account,
      name: 'Врач УЗИ каб. 5',
      timezone: 'Asia/Almaty',
      slot_duration_min: 30,
      active: true
    )
  end
  let(:target_date) { 2.days.from_now.in_time_zone('Asia/Almaty').to_date }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: target_date.wday)
  end

  it 'returns clinic booking configuration without service selector, masks prefill PII with asterisks, and creates an appointment' do
    get '/api/v1/widget/booking', params: { website_token: web_widget.website_token }, headers: headers

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body['enabled']).to be(true)
    expect(body['clinic_preset']).to eq('aliya_center')
    expect(body['services']).to eq([])
    expect(body['show_visit_reason']).to be(true)
    expect(body['specialists'].map { |s| s['id'] }).to include(resource.id.to_s)
    expect(body['prefill']).to include(
      'init_first_name' => 'А**я',
      'init_last_name' => 'Н*******а',
      'init_phone' => '+7701*****22'
    )

    get '/api/v1/widget/booking/slots',
        params: {
          website_token: web_widget.website_token,
          resource_id: resource.id.to_s,
          booking_date: target_date.iso8601
        },
        headers: headers

    expect(response).to have_http_status(:ok)
    slots = response.parsed_body['slots']
    expect(slots).not_to be_empty
    chosen_slot = slots.first

    post '/api/v1/widget/booking',
         params: {
           website_token: web_widget.website_token,
           booking: {
             resource_id: resource.id.to_s,
             booking_date: target_date.iso8601,
             slot_key: chosen_slot['key'],
             visit_reason: 'screening',
             client_first_name: 'А**я',
             client_last_name: 'Н*******а',
             client_phone: '+7701*****22',
             notes: 'Срок 12 недель'
           }
         },
         headers: headers

    expect(response).to have_http_status(:created)
    created = response.parsed_body['appointment']
    expect(created['resource_name']).to eq('Врач УЗИ каб. 5')
    expect(created['client_name']).to eq('А**я Н*******а')
    expect(created['client_phone']).to eq('+7701*****22')

    apt = account.scheduling_appointments.find(created['id'])
    expect(apt.resource_id).to eq(resource.id)
    expect(apt.client_first_name).to eq('Алия')
    expect(apt.client_last_name).to eq('Нурланова')
    expect(apt.client_phone).to eq('+77015551122')
    expect(apt.client_comment).to include('[Скрининг / УЗИ бер.] Срок 12 недель')
  end
end
