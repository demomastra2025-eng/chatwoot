require 'rails_helper'

RSpec.describe 'Appointment persistence with optional CRM linking' do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:contact) { create(:contact, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:pipeline) { account.crm_pipelines.find_by!(code: 'sales_pipeline') }
  let(:stage) { pipeline.stages.find_by!(default: true) }
  let(:starts_at) { 2.days.from_now.in_time_zone(resource.timezone).change(hour: 10, min: 0, sec: 0) }
  let(:booking_key) { SecureRandom.uuid }
  let(:params) { { resource_id: resource.id, contact_id: contact.id, starts_at: starts_at, duration_min: 30, idempotency_key: booking_key } }

  before do
    account.enable_features!('scheduling', 'crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
    pipeline.update!(appointment_automation: { auto_create_from_calendar: true })
    stage.update!(name: 'Чистовая')
    create(:crm_stage_field_requirement, stage: stage, field_key: 'description')
    create(:scheduling_work_rule, resource: resource, weekday: starts_at.wday)
  end

  def book(attributes = params)
    Scheduling::Appointments::UpsertService.new(account: account, actor: actor, params: attributes).perform
  end

  it 'persists a valid booking with an honest missing-field warning and no partial deal or CRM events', :aggregate_failures do
    before_deals = account.crm_deals.count
    before_events = account.crm_events.count
    result = nil

    expect { result = book }.to change(account.scheduling_appointments, :count).by(1)

    expect(result.reload).to have_attributes(status: 'scheduled', crm_deal_id: nil, idempotency_key: booking_key)
    expect(account.crm_deals.count).to eq(before_deals)
    expect(account.crm_events.count).to eq(before_events)
    warning = result.custom_attributes.fetch('crm_link_result')
    expect(warning).to include('status' => 'not_linked', 'code' => 'DEAL_STAGE_REQUIRES_FIELDS')
    expect(warning.dig('details', 'missing_fields')).to include(include('key' => 'description'))
    expect(Scheduling::PayloadBuilder.appointment(result)[:crm_link_result]).to eq(warning)
  end

  it 'keeps strict manual CRM creation validation without fabricating values' do
    expect do
      Crm::Deals::UpsertService.new(
        account: account, actor: actor,
        params: { pipeline_id: pipeline.id, stage_id: stage.id, title: 'Manual deal', contact_ids: [contact.id], primary_contact_id: contact.id }
      ).perform
    end.to raise_error(Crm::Error) { |error| expect(error.code).to eq('DEAL_STAGE_REQUIRES_FIELDS') }
    expect(account.crm_deals).not_to exist
    expect(contact.reload.custom_attributes).not_to have_key('description')
  end

  it 'also preserves the booking when an explicit optional create selection cannot satisfy CRM fields' do
    pipeline.update!(appointment_automation: pipeline.appointment_automation.merge('auto_create_deals' => false))

    result = book(params.merge(crm_deal_selection: 'create', crm_pipeline_id: pipeline.id))

    expect(result.reload).to be_persisted
    expect(result.crm_deal_id).to be_nil
    expect(result.custom_attributes.dig('crm_link_result', 'code')).to eq('DEAL_STAGE_REQUIRES_FIELDS')
    expect(account.crm_deals).not_to exist
  end

  it 'continues provider receipt processing after the appointment has committed with a CRM warning' do
    receipt = instance_double(Integrations::Medelement::AppointmentProviderCommandReceiptService)
    allow(Integrations::Medelement::AppointmentProviderCommandReceiptService).to receive(:new).and_return(receipt)
    expect(receipt).to receive(:perform) do
      persisted = account.scheduling_appointments.find_by!(idempotency_key: booking_key)
      expect(persisted.custom_attributes.dig('crm_link_result', 'status')).to eq('not_linked')
      expect(persisted.crm_deal_id).to be_nil
    end

    expect(book).to be_persisted
  end

  it 'rolls back deal, contacts and events created before a later CRM failure while keeping the booking transaction usable' do
    stage.field_requirements.destroy_all
    before_deals = account.crm_deals.count
    before_contacts = Crm::DealContact.where(account_id: account.id).count
    before_events = account.crm_events.count
    allow(Crm::Deals::UpsertService).to receive(:new).and_wrap_original do |constructor, **arguments|
      service = constructor.call(**arguments)
      allow(service).to receive(:perform).and_wrap_original do |perform|
        perform.call
        raise Crm::Error.new(code: 'VALIDATION_ERROR', message: 'Later CRM validation failed', status: :unprocessable_content)
      end
      service
    end

    result = book

    expect(result.reload).to be_persisted
    expect(result.crm_deal_id).to be_nil
    expect(result.custom_attributes.dig('crm_link_result', 'code')).to eq('VALIDATION_ERROR')
    expect(account.crm_deals.count).to eq(before_deals)
    expect(Crm::DealContact.where(account_id: account.id).count).to eq(before_contacts)
    expect(account.crm_events.count).to eq(before_events)
  end

  it 'rejects explicit foreign links before creating a booking and preserves the provider boundary' do
    foreign = create(:crm_deal)
    expect(Integrations::Medelement::AppointmentProviderCommandReceiptService).not_to receive(:new)

    expect do
      book(params.merge(crm_deal_id: foreign.id))
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('CRM_DEAL_CONTACT_MISMATCH') }
    expect(account.scheduling_appointments).not_to exist
    expect(foreign.reload.appointments).not_to exist
  end

  it 'keeps the system link warning on a later unrelated appointment edit' do
    result = book
    original = result.custom_attributes['crm_link_result']

    updated = Scheduling::Appointments::UpsertService.new(
      account: account, appointment: result, actor: actor, params: { client_comment: 'Changed without retrying CRM' }
    ).perform

    expect(updated.reload.custom_attributes['crm_link_result']).to eq(original)
    expect(updated.client_comment).to eq('Changed without retrying CRM')
  end
end
