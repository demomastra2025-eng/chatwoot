# frozen_string_literal: true

require 'rails_helper'

# The validator charges an upload the physical bytes the account does not hold yet: blobs a counted owner already
# references are free, and a replaced blob is credited only when it loses its last counted owner.
RSpec.describe AccountStorageLimitable do
  let(:account) { create(:account) }
  let(:usage) { AccountLimits::StorageUsageService.new(account: account) }
  let(:limit_message) { AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE }

  def upload(size, name = 'file.txt')
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new('x' * size), filename: name, content_type: 'text/plain')
  end

  before { account.update!(limits: { 'storage_bytes' => 1000 }) }

  describe 'a has_many_attached owner (macro files)' do
    let(:macro) { create(:macro, account: account) }

    before { macro.files.attach(upload(600, 'held.txt')) }

    it 'accepts a small added file near the limit without charging the files the macro already holds' do
      expect(macro.files.attach(upload(100, 'small.txt'))).to be_present

      expect(macro.reload.files.count).to eq(2)
      expect(usage.usage_bytes).to eq(700)
    end

    it 'rejects a file that really goes over the limit and keeps the error on the record' do
      expect(macro.files.attach(upload(500, 'over.txt'))).to be_nil

      expect(macro.errors[:files]).to include(limit_message)
      expect(macro.reload.files.count).to eq(1)
    end

    it 'charges several new files together, each distinct blob once' do
      expect(macro.files.attach([upload(300, 'a.txt'), upload(300, 'b.txt')])).to be_nil
      expect(macro.reload.files.count).to eq(1)

      expect(macro.files.attach([upload(200, 'c.txt'), upload(200, 'd.txt')])).to be_present
      expect(macro.reload.files.count).to eq(3)
    end
  end

  describe 'reusing a blob a counted owner already holds' do
    it 'lets an outgoing message attach a macro file that is already counted' do
      macro = create(:macro, account: account)
      macro.files.attach(upload(600, 'held.txt'))
      attachment = create(:message, account: account).attachments.new(account_id: account.id, file_type: :file)

      attachment.file.attach(macro.files.first.blob)

      expect(attachment).to be_valid
      expect(attachment.save).to be(true)
      expect(usage.usage_bytes).to eq(600)
    end

    it 'still charges a blob nobody holds yet' do
      attachment = create(:message, account: account).attachments.new(account_id: account.id, file_type: :file)

      attachment.file.attach(upload(1100, 'new.txt'))

      expect(attachment).not_to be_valid
      expect(attachment.errors[:file]).to include(limit_message)
    end
  end

  describe 'replacing a single attachment (account logo)' do
    let(:held) { upload(600, 'logo.txt') }

    before { account.logo.attach(held) }

    it 'credits the replaced blob when the logo was its last counted owner' do
      expect(account.logo.attach(upload(900, 'new-logo.txt'))).to be_present
      expect(account.reload.logo.blob.byte_size).to eq(900)
    end

    it 'credits nothing when another counted record still holds the replaced blob' do
      create(:macro, account: account).files.attach(held)

      expect(account.logo.attach(upload(900, 'new-logo.txt'))).to be_nil
      expect(account.errors[:logo]).to include(limit_message)
      expect(account.reload.logo.blob).to eq(held)
    end

    it 'still rejects a replacement that is bigger than the limit even after the credit' do
      expect(account.logo.attach(upload(1100, 'huge-logo.txt'))).to be_nil
    end
  end

  describe 'an exempt record' do
    it 'skips the check for a record flagged as an automatic writer' do
      contact = create(:contact, account: account)
      contact.skip_storage_limit_validation!

      expect(contact.avatar.attach(io: StringIO.new('a' * 1500), filename: 'avatar.png', content_type: 'image/png')).to be_present
    end
  end
end
