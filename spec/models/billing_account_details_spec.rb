require 'rails_helper'

RSpec.describe BillingAccount do
  describe 'payer details' do
    it 'keeps legacy accounts valid without payer details' do
      expect(build(:billing_account)).to be_valid
    end

    it 'normalizes typed details while preserving unrelated metadata' do
      account = create(:billing_account, metadata: { 'internal_note' => { 'retained' => true } },
                                         legal_name: ' Example LLP ', billing_email: ' billing@example.test ', billing_country: ' kz ')

      expect(account.reload).to have_attributes(legal_name: 'Example LLP', billing_email: 'billing@example.test', billing_country: 'KZ')
      expect(account.metadata['internal_note']).to eq('retained' => true)
    end

    it 'allows clearing optional details' do
      account = create(:billing_account, tax_id: '123456789012')
      account.update!(tax_id: '  ')

      expect(account.reload.tax_id).to be_nil
    end

    {
      payer_type: 'unknown', billing_email: 'invalid', billing_country: 'KAZ',
      legal_name: 'a' * 256, billing_address: 'a' * 1001, tax_id: { 'nested' => 'invalid' }
    }.each do |field, value|
      it "rejects invalid #{field}" do
        account = build(:billing_account, field => value)

        expect(account).not_to be_valid
        expect(account.errors[field]).to be_present
      end
    end

    it 'rejects non-object metadata without raising' do
      account = build(:billing_account, metadata: ['invalid'])

      expect(account).not_to be_valid
      expect(account.errors[:metadata]).to be_present
    end
  end

  describe '#current_subscription' do
    it 'prefers the entitling subscription to newer historical rows' do
      account = create(:billing_account)
      active = create(:billing_subscription, billing_account: account)
      create(:billing_subscription, billing_account: account, status: 'canceled')

      expect(account.current_subscription).to eq(active)
    end

    it 'returns the latest non-entitling state when there is no entitling subscription' do
      account = create(:billing_account)
      create(:billing_subscription, billing_account: account, status: 'canceled')
      suspended = create(:billing_subscription, billing_account: account, status: 'suspended')

      expect(account.current_subscription).to eq(suspended)
    end
  end
end
