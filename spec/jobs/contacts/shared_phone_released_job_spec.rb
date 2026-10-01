require 'rails_helper'

# M5(b): when a number stops being someone's primary, every relative that has it as доп. номер gets a promotion hint.
RSpec.describe Contacts::SharedPhoneReleasedJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: phone) }
  let!(:son) { shared_phone_card(account, mother) }
  let!(:daughter) { shared_phone_card(account, mother, code: 'daughter-1', name: 'Daughter') }

  def hint(contact) = contact.reload.custom_attributes[Contacts::SharedPhone::HINT_KEY]

  def sealed(number) = described_class.encryptor.encrypt_and_sign(number)

  def enqueued_numbers
    enqueued_jobs.select { |job| job[:job] == described_class }.map { |job| described_class.encryptor.decrypt_and_verify(job[:args].second) }
  end

  it 'is enqueued when a primary number changes away or its holder is deleted, not on other updates', :aggregate_failures do
    expect { mother.update!(name: 'Mom') }.not_to have_enqueued_job(described_class)
    expect { mother.update!(phone_number: '+77000000008') }.to have_enqueued_job(described_class).with(account.id, anything, mother.id)
    expect { mother.destroy! }.to have_enqueued_job(described_class).with(account.id, anything, mother.id)
    expect(enqueued_numbers).to eq([phone, '+77000000008'])
  end

  it 'never carries the released number in clear text in the queue payload or the job log', :aggregate_failures do
    mother.update!(phone_number: '+77000000008')
    payload = enqueued_jobs.select { |job| job[:job] == described_class }.to_json

    expect(payload).not_to include(phone.delete('+'))
    expect(described_class.log_arguments?).to be(false)
  end

  it 'gives every relative with the number as доп. номер a hint naming the siblings', :aggregate_failures do
    perform_enqueued_jobs(only: described_class) { mother.update!(phone_number: '+77000000008') }

    expect(hint(son)).to include('phone' => phone, 'previous_holder_contact_id' => mother.id, 'reason' => 'released',
                                 'candidate_contact_ids' => [son.id, daughter.id], 'dismissed_at' => nil)
    expect(hint(daughter)).to include('candidate_contact_ids' => [son.id, daughter.id])
    expect(hint(mother)).to be_nil
  end

  it 'creates no hint when the number is someone primary again or reserved for a hidden share', :aggregate_failures do
    mother.update_columns(phone_number: '+77000000008') # rubocop:disable Rails/SkipsModelValidations
    create(:contact, account: account, phone_number: phone)
    described_class.perform_now(account.id, sealed(phone), mother.id)
    expect(hint(son)).to be_nil

    Contact.where(phone_number: phone).update_all(phone_number: nil) # rubocop:disable Rails/SkipsModelValidations
    hidden_owner = create(:contact, account: account, phone_number: nil)
    shared_phone_card(account, hidden_owner, via: 'booking_chat', code: 'other-1', name: 'Other')
    described_class.perform_now(account.id, sealed(phone), mother.id)
    expect(hint(son)).to be_nil
  end

  it 'drops the hint once the card takes its own number and hides a dismissed hint', :aggregate_failures do
    perform_enqueued_jobs(only: described_class) { mother.update!(phone_number: '+77000000008') }
    Contacts::SharedPhoneHint.dismiss!(daughter.reload)
    expect(Contacts::SharedPhoneHint.visible(daughter.reload)).to be_nil
    expect(hint(daughter)['dismissed_at']).to be_present

    son.reload.update!(phone_number: '+77000000002')
    expect(hint(son)).to be_nil
  end
end
