require 'rails_helper'

RSpec.describe LeadForms::MetaProcessService do
  let(:account) { create(:account).tap { |record| record.enable_features!('crm_deals') } }
  let(:target_inbox) { create(:inbox, account: account) }
  let(:meta_channel) { create(:channel_instagram, account: account) }
  let(:lead_form) do
    create(
      :lead_form,
      account: account,
      inbox: target_inbox,
      source_kind: 'meta',
      external_ref: 'meta-form-1',
      field_schema: [{ 'name' => 'email', 'label' => 'Email', 'type' => 'email', 'required' => true }],
      settings: { 'meta_connection_inbox_id' => meta_channel.inbox.id }
    )
  end

  it 'fetches Meta lead details through the registered Meta channel and ingests the submission' do
    stub_meta_lead_fetch('lead-1', 'email', 'lead@example.com')

    described_class.new(payload: meta_payload(lead_id: 'lead-1')).perform
    submission = account.lead_submissions.last

    expect(submission).to be_processed
    expect(submission.lead_form).to eq(lead_form)
    expect(submission.field_values).to include('email' => 'lead@example.com')
    expect(submission.conversation).to be_present
    expect(submission.crm_deal).to be_present
  end

  it 'updates a previously received stub when Meta details become available' do
    stub = lead_form.lead_submissions.create!(
      account: account,
      inbox: target_inbox,
      source_kind: 'meta',
      status: 'received',
      external_ref: 'lead-2',
      idempotency_key: 'lead-2',
      field_values: {},
      payload: { 'leadgen_id' => 'lead-2' },
      processing_errors: { 'code' => 'META_FIELD_DATA_NOT_FETCHED' }
    )
    stub_meta_lead_fetch('lead-2', 'email', 'lead2@example.com')

    described_class.new(payload: meta_payload(lead_id: 'lead-2')).perform

    expect(stub.reload).to be_processed
    expect(stub.field_values).to include('email' => 'lead2@example.com')
    expect(stub.processing_errors).to eq({})
  end

  def meta_payload(lead_id:)
    {
      entry: [
        {
          id: 'page-1',
          changes: [
            {
              field: 'leadgen',
              value: {
                leadgen_id: lead_id,
                form_id: lead_form.external_ref,
                page_id: 'page-1'
              }
            }
          ]
        }
      ]
    }
  end

  def stub_meta_lead_fetch(lead_id, field_name, field_value)
    stub_request(:get, "https://graph.facebook.com/v18.0/#{lead_id}")
      .with(query: hash_including(access_token: meta_channel.access_token))
      .to_return(
        status: 200,
        body: {
          id: lead_id,
          form_id: lead_form.external_ref,
          field_data: [{ name: field_name, values: [field_value] }]
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end
end
