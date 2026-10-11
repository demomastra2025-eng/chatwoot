require 'rails_helper'

RSpec.describe Crm::Appointments::LinkService do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:patient) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:pipeline) { create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true) }
  let!(:stage) { create(:crm_stage, account: account, pipeline: pipeline, default: true) }
  let(:deal) do
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage).tap do |record|
      create(:crm_deal_contact, account: account, deal: record, contact: contact, primary: true)
    end
  end

  before { account.enable_features!('crm_deals') }

  def appointment(**attributes)
    build(:scheduling_appointment, account: account, contact: contact, patient_contact: patient,
                                   conversation: conversation, **attributes)
  end

  def link(appointment, params = {}, **options)
    described_class.new(appointment: appointment, params: params, **options).perform
  end

  it 'keeps the explicit source for the first booking and creates a separate deal for the next distinct appointment' do
    pipeline.update!(appointment_automation: { auto_create_deals: true, cardinality: 'appointment' })
    first = appointment
    expect(link(first, { crm_deal_id: deal.id })).to eq(deal)
    first.save!

    second = appointment
    split = link(second, { crm_deal_id: deal.id })
    second.save!
    expect(split.id).not_to eq(deal.id)
    expect(split.pipeline_id).to eq(pipeline.id)
    expect(split.primary_contact_id).to eq(contact.id)
    expect(split.contact_ids).to contain_exactly(contact.id, patient.id)
    expect(first.reload.crm_deal_id).to eq(deal.id)
  end

  it 'retains the original deal for rescheduling the same appointment after a mode change' do
    original = appointment
    link(original, { crm_deal_id: deal.id })
    original.save!
    pipeline.update!(appointment_automation: { cardinality: 'appointment' })
    original.assign_attributes(starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)

    expect { link(original, { crm_deal_selection: 'create', crm_pipeline_id: pipeline.id }) }.not_to change(Crm::Deal, :count)
    expect(original.crm_deal_id).to eq(deal.id)
  end

  it 'reuses one communication-contact deal for different clinical patients in request mode' do
    first = appointment
    link(first, { crm_deal_id: deal.id })
    first.save!
    other_patient = create(:contact, account: account)
    second = appointment(patient_contact: other_patient)

    expect(link(second).id).to eq(deal.id)
    expect(second.patient_contact_id).to eq(other_patient.id)
    expect(second.contact_id).to eq(contact.id)
  end

  it 'reports an unlinked booking when several active deals match and still honors explicit selection' do
    deal
    another = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    create(:crm_deal_contact, account: account, deal: another, contact: contact, primary: true)

    ambiguous = appointment
    expect(link(ambiguous)).to be_nil
    expect(ambiguous.crm_deal_id).to be_nil
    expect(ambiguous.custom_attributes.dig('crm_link_result', 'code')).to eq('CRM_DEAL_SELECTION_REQUIRED')
    explicit = appointment
    expect(link(explicit, { crm_deal_id: another.id })).to eq(another)
    expect(link(appointment, { crm_deal_selection: 'create', crm_pipeline_id: pipeline.id }).id).not_to be_in([deal.id, another.id])
  end

  it 'does not match a clinical-only contact or an unrelated contact with the same phone' do
    pipeline.update!(appointment_automation: { auto_create_from_calendar: true })
    unrelated = create(:contact, account: account)
    unrelated.update_columns(phone_number: contact.phone_number)
    unrelated_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    create(:crm_deal_contact, account: account, deal: unrelated_deal, contact: unrelated, primary: true)
    create(:crm_deal_contact, account: account, deal: unrelated_deal, contact: contact, primary: false)

    expect(link(appointment).id).not_to eq(unrelated_deal.id)
  end

  it 'rejects a deal from a different account or communication contact' do
    foreign = create(:crm_deal)

    expect { link(appointment, { crm_deal_id: foreign.id }) }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('CRM_DEAL_CONTACT_MISMATCH') }
    expect { link(appointment, { crm_deal_selection: 'create', crm_pipeline_id: foreign.pipeline_id }) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'uses an independently enabled calendar target and does not infer it from inbound auto-create' do
    direct = appointment(conversation: nil)
    expect(link(direct)).to be_nil
    pipeline.update!(appointment_automation: { auto_create_from_calendar: true })

    expect(link(direct).pipeline_id).to eq(pipeline.id)
    expect(Crm::Appointments::Configuration.for(pipeline)['auto_create_from_medelement']).to be false
  end

  it 'links only newly imported provider appointments whose source creation is after enablement' do
    pipeline.update!(appointment_automation: { auto_create_from_medelement: true })
    imported = create(:scheduling_appointment, account: account, contact: contact, conversation: nil, source: 'medelement',
                                              custom_attributes: { medelement_source_created_at: 1.minute.from_now.iso8601 })
    historical = create(:scheduling_appointment, account: account, contact: contact, conversation: nil, source: 'medelement',
                                                custom_attributes: { medelement_source_created_at: 2.days.ago.iso8601 })
    missing = create(:scheduling_appointment, account: account, contact: contact, conversation: nil, source: 'medelement')

    expect(link(historical, {}, newly_imported: true)).to be_nil
    expect(link(missing, {}, newly_imported: true)).to be_nil
    linked = link(imported, {}, newly_imported: true)
    imported.save!
    expect(linked.pipeline_id).to eq(pipeline.id)
    expect { link(imported.reload, {}, newly_imported: true) }.not_to change(Crm::Deal, :count)
    expect(imported.crm_deal_id).to eq(linked.id)
  end

  it 'treats an ordinary new appointment after cancellation according to current pipeline rules' do
    pipeline.update!(appointment_automation: { auto_create_deals: true, cardinality: 'appointment' })
    cancelled = appointment(status: 'cancelled')
    link(cancelled, { crm_deal_id: deal.id })
    cancelled.save!
    fresh = appointment

    expect(link(fresh, { crm_deal_id: deal.id }).id).not_to eq(deal.id)
    expect(cancelled.reload.status).to eq('cancelled')
    expect(cancelled.crm_deal_id).to eq(deal.id)
  end

  it 'compares SQL and day-month-year provider creation timestamps in the provider timezone at enablement' do
    travel_to(Time.utc(2026, 10, 10, 7)) do
      pipeline.update!(appointment_automation: { auto_create_from_medelement: true })
      resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')
      fresh_sql = create(:scheduling_appointment, account: account, resource: resource, contact: contact, source: 'medelement',
                                                 custom_attributes: { medelement_source_created_at: '2026-10-10 12:01:00' })
      fresh_dmy = create(:scheduling_appointment, account: account, resource: resource, contact: contact, source: 'medelement',
                                                 custom_attributes: { medelement_source_created_at: '10.10.2026 12:01:00' })
      old_sql = create(:scheduling_appointment, account: account, resource: resource, contact: contact, source: 'medelement',
                                               custom_attributes: { medelement_source_created_at: '2026-10-10 11:59:00' })

      expect(link(old_sql, {}, newly_imported: true)).to be_nil
      expect(link(fresh_sql, {}, newly_imported: true)).to be_present
      fresh_sql.save!
      expect(link(fresh_dmy, {}, newly_imported: true).id).to eq(fresh_sql.crm_deal_id)
    end
  end

  it 'creates in an explicitly selected pipeline only when automatic appointment creation is enabled' do
    target = create(:crm_pipeline, account: account, appointment_automation: { auto_create_deals: true })
    create(:crm_stage, account: account, pipeline: target, default: true)

    expect(link(appointment, { crm_pipeline_id: target.id }).pipeline_id).to eq(target.id)
  end

  it 'does not treat a pipeline selector alone as permission to bypass master OFF' do
    booking = appointment

    expect { expect(link(booking, { crm_pipeline_id: pipeline.id })).to be_nil }.not_to change(Crm::Deal, :count)
    expect(link(appointment, { crm_pipeline_id: pipeline.id, crm_deal_id: deal.id })).to eq(deal)
  end

  it 'does not create a deal for a dialog appointment from the channel incoming switch alone' do
    booking = appointment

    expect { expect(link(booking)).to be_nil }.not_to change(Crm::Deal, :count)
    expect(booking.crm_deal_id).to be_nil
    expect(Crm::Appointments::Configuration.for(pipeline)['auto_create_deals']).to be false
  end

  it 'honors master OFF with both source toggles retained and a channel configured to create deals' do
    pipeline.update!(appointment_automation: {
                       auto_create_deals: false, auto_create_from_calendar: true, auto_create_from_medelement: true
                     })
    direct = appointment(conversation: nil)
    dialog = appointment
    imported = create(:scheduling_appointment, account: account, contact: contact, source: 'medelement',
                                              custom_attributes: { medelement_source_created_at: 1.minute.from_now.iso8601 })

    expect do
      expect(link(direct)).to be_nil
      expect(link(dialog)).to be_nil
      expect(link(imported, {}, newly_imported: true)).to be_nil
    end.not_to change(Crm::Deal, :count)
    expect(pipeline.reload.appointment_automation).to include('auto_create_deals' => false, 'auto_create_from_calendar' => true)
  end

  it 'links an explicit existing deal without cloning while master creation is OFF' do
    pipeline.update!(appointment_automation: { auto_create_deals: false, cardinality: 'appointment' })
    first = appointment
    link(first, { crm_deal_id: deal.id })
    first.save!
    second = appointment

    expect { expect(link(second, { crm_deal_id: deal.id })).to eq(deal) }.not_to change(Crm::Deal, :count)
    expect(second.crm_deal_id).to eq(deal.id)
  end

  it 'allows an explicit create selection while automatic creation is OFF' do
    booking = appointment

    expect(link(booking, { crm_deal_selection: 'create', crm_pipeline_id: pipeline.id })).to be_present
    expect(Crm::Appointments::Configuration.for(pipeline)['auto_create_deals']).to be false
  end
end
