require 'rails_helper'

RSpec.describe Campaigns::AudienceImportService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_sms, account: account)) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:audience_import) do
    create(
      :campaign_audience_import,
      account: account,
      inbox: inbox,
      created_by: administrator,
      status: :pending,
      source_filename: 'recipients.csv'
    )
  end

  def attach_csv(rows)
    csv = CSV.generate do |value|
      rows.each { |row| value << row }
    end
    audience_import.import_file.attach(
      io: StringIO.new(csv),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )
  end

  it 'normalizes KZ numbers, deduplicates rows, names new contacts by phone, and preserves existing contact data' do
    existing = create(:contact, account: account, name: 'Existing name', phone_number: '+77051234568', email: 'existing@example.com')
    attach_csv([
                 %w[phone_number name email],
                 ['8 (705) 123-45-67', 'New recipient', 'new@example.com'],
                 ['+7 705 123 45 68', 'Overwrite attempt', 'existing@example.com'],
                 ['87051234567', 'Duplicate', 'duplicate@example.com'],
                 ['not-a-phone', 'Invalid', 'invalid@example.com']
               ])

    result = described_class.new(audience_import: audience_import).perform

    expect(result).to be_completed
    expect(result.attributes).to include(
      'total_rows' => 4,
      'recipient_count' => 2,
      'created_count' => 1,
      'existing_count' => 1,
      'duplicate_count' => 1,
      'invalid_count' => 1,
      'conflict_count' => 0
    )
    expect(result.recipients.order(:source_row).pluck(:normalized_phone_number)).to eq(%w[+77051234567 +77051234568])
    created_recipient = result.recipients.find_by!(contact_created: true)
    expect(created_recipient.contact.name).to eq(created_recipient.normalized_phone_number)
    expect(existing.reload.attributes).to include('name' => 'Existing name', 'email' => 'existing@example.com')
  end

  it 'rejects conflicting identity fields without mutating or merging contacts' do
    email_owner = create(:contact, account: account, email: 'owned@example.com', phone_number: '+77050000001')
    attach_csv([
                 %w[phone_number name email],
                 ['87050000002', 'Conflicting', 'owned@example.com']
               ])

    result = described_class.new(audience_import: audience_import).perform

    expect(result).to be_completed
    expect(result.recipient_count).to eq(0)
    expect(result.conflict_count).to eq(1)
    expect(result.error_samples).to contain_exactly('row' => 2, 'code' => 'identity_conflict')
    expect(email_owner.reload.phone_number).to eq('+77050000001')
    expect(account.contacts.where(phone_number: '+77050000002')).not_to exist
  end

  it 'fails closed when legacy duplicate contacts already own the normalized phone' do
    phone_number = '+77050000003'
    create(:contact, account: account, phone_number: phone_number)
    duplicate = build(:contact, account: account, phone_number: phone_number)
    duplicate.save!(validate: false)
    attach_csv([%w[phone_number], ['87050000003']])

    result = described_class.new(audience_import: audience_import).perform

    expect(result.recipient_count).to eq(0)
    expect(result.conflict_count).to eq(1)
    expect(result.error_samples).to contain_exactly('row' => 2, 'code' => 'duplicate_existing_contacts')
  end

  it 'holds all contact identity locks until the import transaction commits' do
    attach_csv([%w[phone_number], ['87050000004']])
    connection = ActiveRecord::Base.connection
    lock_transaction_states = []
    lock_statements = []
    allow(connection).to receive(:execute).and_wrap_original do |original, statement, *args|
      if statement.include?('pg_advisory_xact_lock')
        lock_transaction_states << connection.transaction_open?
        lock_statements << statement
      end
      original.call(statement, *args)
    end

    described_class.new(audience_import: audience_import).perform

    expect(lock_transaction_states).not_to be_empty
    expect(lock_transaction_states).to all(be(true))
    expect(lock_statements.uniq.one?).to be(true)
  end

  it 'rejects files without a supported phone column' do
    attach_csv([%w[name email], ['No phone', 'none@example.com']])

    expect { described_class.new(audience_import: audience_import).perform }
      .to raise_error(described_class::Error, 'phone_column_required')
  end

  it 'rejects invalid UTF-8 without creating contacts or recipients' do
    audience_import.import_file.attach(
      io: StringIO.new("phone_number,name\n87051234567,\xFF\n".b),
      filename: 'recipients.csv',
      content_type: 'text/csv'
    )

    expect do
      described_class.new(audience_import: audience_import).perform
    end.to raise_error(described_class::Error, 'invalid_encoding')
      .and not_change(Contact, :count)
      .and not_change(CampaignAudienceRecipient, :count)
  end

  it 'stops parsing as soon as the row limit is exceeded' do
    rows = Array.new(described_class::MAX_ROWS + 1) { ['87051234567'] }
    attach_csv([['phone_number'], *rows])

    expect do
      described_class.new(audience_import: audience_import).perform
    end.to raise_error(described_class::Error, 'too_many_rows')
  end
end
