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
        phone_number: '+77010000000'
      },
      landing_url: 'https://example.com/landing?utm_source=meta',
      utm_source: 'meta'
    }
  end

  it 'creates native contact, conversation, lead submission, and CRM deal' do
    submission = described_class.new(lead_form: lead_form, params: payload).perform

    expect(submission).to be_processed
    expect(submission.contact.email).to eq('client@example.com')
    expect(submission.conversation).to be_present
    expect(submission.conversation.messages.last.content).to include('Новая заявка')
    expect(submission.crm_deal).to be_present
    expect(submission.crm_deal.originating_conversation_id).to eq(submission.conversation_id)
    expect(submission.utm).to include('utm_source' => 'meta')
  end

  it 'is idempotent by idempotency key' do
    first_submission = described_class.new(lead_form: lead_form, params: payload).perform
    second_submission = described_class.new(lead_form: lead_form, params: payload).perform

    expect(second_submission.id).to eq(first_submission.id)
    expect(account.lead_submissions.count).to eq(1)
    expect(account.conversations.count).to eq(1)
    expect(account.crm_deals.count).to eq(1)
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
      params: payload.merge(access_token: 'secret-token')
    ).perform

    expect(submission.payload['access_token']).to eq('[REDACTED]')
  end
end
