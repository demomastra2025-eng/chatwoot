require 'rails_helper'

RSpec.describe LeadForms::IngestSubmissionService do
  let(:account) { create(:account).tap { |record| record.enable_features!('crm_deals') } }
  let(:inbox) { create(:inbox, account: account) }
  let(:lead_form) { create(:lead_form, account: account, inbox: inbox) }
  let(:payload) do
    {
      idempotency_key: 'landing-123',
      field_values: {
        full_name: 'Aigerim Client',
        email: 'client@example.com',
        phone_number: '+77005550000'
      },
      landing_url: 'https://example.com/landing?utm_source=meta',
      utm_source: 'meta'
    }
  end

  it 'creates native contact, conversation, lead submission, and visual form message' do
    submission = described_class.new(lead_form: lead_form, params: payload).perform

    expect(submission).to be_processed
    expect(submission.contact.email).to eq('client@example.com')
    expect(submission.conversation).to be_present
    expect(submission.conversation.messages.last.content).to include('Новая заявка')
    expect(submission.conversation.messages.last.content_type).to eq('form')
    submitted_values = submission.conversation.messages.last.content_attributes['submitted_values']
    phone_value = submitted_values.map(&:with_indifferent_access).find { |value| value[:name] == 'phone_number' }
    expect(phone_value[:value]).to eq(submission.field_values['phone_number'])
    expect(account.crm_deals.count).to eq(0)
    expect(submission.utm).to include('utm_source' => 'meta')
  end

  it 'lets the existing conversation auto-create pipeline setting create the deal when enabled' do
    pipeline = create(
      :crm_pipeline,
      account: account,
      default: true,
      auto_create_deal_on_channel_contact: true
    )
    create(:crm_stage, account: account, pipeline: pipeline, default: true)

    submission = described_class.new(lead_form: lead_form, params: payload).perform

    deal = account.crm_deals.find_by!(pipeline: pipeline)
    expect(deal.originating_conversation_id).to eq(submission.conversation_id)
    expect(deal.primary_contact_id).to eq(submission.contact_id)
    expect(deal.idempotency_key).to eq("auto_channel_contact:pipeline:#{pipeline.id}:conversation:#{submission.conversation_id}")
  end

  it 'is idempotent by idempotency key' do
    first_submission = described_class.new(lead_form: lead_form, params: payload).perform
    second_submission = described_class.new(lead_form: lead_form, params: payload).perform

    expect(second_submission.id).to eq(first_submission.id)
    expect(account.lead_submissions.count).to eq(1)
    expect(account.conversations.count).to eq(1)
    expect(account.crm_deals.count).to eq(0)
  end

  it 'normalizes a contact phone into stored form values and the form message' do
    submission = described_class.new(
      lead_form: lead_form,
      params: payload.except(:field_values).merge(
        contact: { phone_number: '+77005550123' },
        field_values: { full_name: 'Contact Phone Lead', email: 'contact-phone@example.com' }
      )
    ).perform

    expect(submission.field_values['phone_number']).to eq('+77005550123')
    submitted_values = submission.conversation.messages.last.content_attributes['submitted_values']
    phone_value = submitted_values.map(&:with_indifferent_access).find { |value| value[:name] == 'phone_number' }
    expect(phone_value[:value]).to eq('+77005550123')
  end

  it 'scopes idempotency keys by lead form' do
    another_form = create(:lead_form, account: account, inbox: inbox, name: 'Second landing form')

    described_class.new(lead_form: lead_form, params: payload).perform
    described_class.new(lead_form: another_form, params: payload).perform

    expect(account.lead_submissions.count).to eq(2)
    expect(account.conversations.count).to eq(2)
  end

  it 'rejects submissions missing required form schema fields' do
    lead_form.update!(
      field_schema: [
        { 'name' => 'fullName', 'label' => 'Client name', 'type' => 'text', 'required' => true },
        { 'name' => 'phoneNumber', 'label' => 'Phone number', 'type' => 'tel', 'required' => true },
        { 'name' => 'comment', 'label' => 'Comment', 'type' => 'textarea', 'required' => false }
      ]
    )

    expect do
      described_class.new(
        lead_form: lead_form,
        params: payload.merge(field_values: { comment: 'Need consultation' })
      ).perform
    end.to raise_error(ArgumentError, /Client name/)

    expect(account.lead_submissions.count).to eq(0)
  end

  it 'redacts secret-like fields from stored payload' do
    submission = described_class.new(
      lead_form: lead_form,
      params: payload.merge(access_token: 'secret-token', apiKey: 'secret-api-key')
    ).perform

    expect(submission.payload['access_token']).to eq('[REDACTED]')
    expect(submission.payload['apiKey']).to eq('[REDACTED]')
  end
end
