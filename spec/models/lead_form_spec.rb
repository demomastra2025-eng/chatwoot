require 'rails_helper'

RSpec.describe LeadForm do
  it 'generates a public token' do
    form = create(:lead_form)

    expect(form.public_token).to be_present
  end

  it 'requires inbox to belong to the same account' do
    form = build(:lead_form, account: create(:account), inbox: create(:inbox))

    expect(form).not_to be_valid
    expect(form.errors[:inbox_id]).to include('must belong to the same account')
  end

  it 'accepts account-owned Meta channel as a Meta lead registration connection' do
    account = create(:account)
    instagram_channel = create(:channel_instagram, account: account)
    form = build(
      :lead_form,
      account: account,
      inbox: instagram_channel.inbox,
      source_kind: 'meta',
      external_ref: 'meta-form-123',
      settings: { 'meta_connection_inbox_id' => instagram_channel.inbox.id }
    )

    expect(form).to be_valid
  end

  it 'rejects non-Meta inboxes as Meta registration connections' do
    account = create(:account)
    widget_inbox = create(:inbox, account: account)
    form = build(
      :lead_form,
      account: account,
      inbox: widget_inbox,
      source_kind: 'meta',
      external_ref: 'meta-form-456',
      settings: { 'meta_connection_inbox_id' => widget_inbox.id }
    )

    expect(form).not_to be_valid
    expect(form.errors[:settings]).to include('meta connection inbox must be a Meta channel')
  end

  it 'requires a required phone field for every lead form source' do
    account = create(:account)
    form = build(
      :lead_form,
      account: account,
      inbox: create(:inbox, account: account),
      source_kind: 'meta',
      external_ref: 'meta-form-without-phone',
      field_schema: [{ 'name' => 'full_name', 'label' => 'Name', 'type' => 'text', 'required' => true }],
      settings: { 'meta_connection_inbox_id' => create(:channel_instagram, account: account).inbox.id }
    )

    expect(form).not_to be_valid
    expect(form.errors[:field_schema]).to include('must include an enabled required phone number field')
  end

  it 'requires API field schema labels' do
    account = create(:account)
    form = build(
      :lead_form,
      account: account,
      inbox: create(:inbox, account: account),
      field_schema: [{ 'name' => 'phone_number', 'type' => 'tel', 'required' => true }]
    )

    expect(form).not_to be_valid
    expect(form.errors[:field_schema]).to include('field label is required')
  end
end
