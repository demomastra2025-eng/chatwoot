require 'rails_helper'

RSpec.describe Captain::Tools::Agent::PatientBookingContext do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:mother) { create(:contact, account: account, name: 'Test Mother', phone_number: '+77010000001') }
  let(:conversation) { create(:conversation, account: account, contact: mother) }
  let(:details) { { first_name: 'Test', last_name: 'Son', iin: '940720300129', birth_date: '1994-07-20', phone: '+77010000002' } }

  def resolve(patient = details)
    described_class.new(assistant: assistant, conversation: conversation, patient: patient).perform
  end

  it 'creates a distinct patient with another phone, preserves the caller and reuses the same card on retry' do
    original = mother.reload.attributes
    result = resolve
    card = account.contacts.find(result[:patient_contact_id])
    expect(card.id).not_to eq(mother.id)
    expect(card.phone_number).to eq('+77010000002')
    expect(mother.reload.attributes).to eq(original)
    expect(conversation.reload.contact_id).to eq(mother.id)
    expect(resolve[:patient_contact_id]).to eq(card.id)
    expect(Captain::Tools::Agent::AppointmentAccess.valid_patient_selection?(
             token: result[:patient_selection_token], assistant: assistant, contact: mother, patient_id: card.id
           )).to be(true)
  end

  it 'reuses a recorded exact IIN without rewriting its clinical identity or phone' do
    card = create(:contact, account: account, name: 'Test', last_name: 'Son', middle_name: 'Recorded', phone_number: '+77010000003',
                            identifier: '940720300129', custom_attributes: {
                              Contacts::SharedPhone::CARD_KEY => true, 'iin' => '940720300129', 'birth_date' => '1994-07-20'
                            })
    original = card.reload.attributes
    expect(resolve[:patient_contact_id]).to eq(card.id)
    expect(card.reload.attributes).to eq(original)
    expect { resolve(details.merge(last_name: 'Other')) }.to raise_error(ArgumentError, /name/)
    expect { resolve(details.merge(birth_date: '1994-07-21')) }.to raise_error(ArgumentError, /birth date/)
    expect(card.reload.attributes).to eq(original)
  end

  it 'does not adopt self-declared public IIN or a matching card from another workspace' do
    public_card = create(:contact, account: account, identifier: '940720300129')
    foreign = create(:contact, identifier: '940720300129', custom_attributes: { Contacts::SharedPhone::CARD_KEY => true })
    result = resolve
    expect(result[:patient_contact_id]).not_to eq(public_card.id)
    expect(result[:patient_contact_id]).not_to eq(foreign.id)
  end

  it 'rejects invalid identity and cross-account context before creating a patient' do
    expect { resolve(details.merge(iin: '123456789012')) }.to raise_error(ArgumentError)
    expect { resolve(details.merge(birth_date: '1994-02-31')) }.to raise_error(ArgumentError)
    expect do
      described_class.new(assistant: create(:captain_assistant), conversation: conversation, patient: details).perform
    end.to raise_error(ArgumentError)
    expect(account.contacts.count).to eq(1)
  end

  it 'splits Kazakh female+male and male+male name pairs and rejects birth-date-shaped IIN checksum typos before DB' do
    female_male_ctx = described_class.new(
      assistant: assistant, conversation: conversation,
      patient: details.merge(first_name: 'Айбек Аружан', last_name: 'Айбек Аружан')
    )
    expect(female_male_ctx.send(:patient)[:first_name]).to eq('Аружан')
    expect(female_male_ctx.send(:patient)[:last_name]).to eq('Айбек')

    card = create(:contact, account: account, name: 'Болат', last_name: 'Айбек', phone_number: '+77010000009',
                            identifier: '940720300129', custom_attributes: {
                              Contacts::SharedPhone::CARD_KEY => true, 'iin' => '940720300129', 'birth_date' => '1994-07-20'
                            })
    aligned_res = resolve(details.merge(first_name: 'Айбек Болат', last_name: 'Айбек Болат'))
    expect(aligned_res[:patient_contact_id]).to eq(card.id)

    # Checksum typo on birth-date-shaped IIN is masked by IinValidator in text, but strictly rejected by booking context
    typo_iin = '940720300128'
    expect(Scheduling::IinValidator.redact_text("ИИН #{typo_iin}")).to eq('ИИН [ИИН СКРЫТ]')
    expect { resolve(details.merge(iin: typo_iin)) }.to raise_error(ArgumentError, /Invalid patient IIN/)
  end

  it 'only verifies learning after matching an existing recorded identity in the same account' do
    card = create(:contact, account: account, name: 'Test', last_name: 'Son',
                            identifier: '940720300129', custom_attributes: {
                              Contacts::SharedPhone::CARD_KEY => true, 'iin' => '940720300129', 'birth_date' => '1994-07-20'
                            })
    expect(Llm::PiiShadowAuditor).not_to receive(:record_verified_patient!)
    expect { resolve(details.merge(last_name: 'Mismatch')) }.to raise_error(ArgumentError, /name/)
    expect { resolve(details.merge(birth_date: '1994-07-21')) }.to raise_error(ArgumentError, /birth date/)
    RSpec::Mocks.space.proxy_for(Llm::PiiShadowAuditor).reset
    expect(Llm::PiiShadowAuditor).to receive(:record_verified_patient!).with(contact: card, account_id: account.id).once
    resolve
  end

  it 'never treats new or publicly self-declared patient cards as verified learning' do
    with_modified_env(PII_SHADOW_AUDIT_ENABLED: 'true') do
      expect(Llm::PiiNameLexicon).not_to receive(:learn_word!)
      create(:contact, account: account, identifier: '940720300129')
      2.times { resolve }
    end
  end

  it 'promotes a quarantined verified name only for its account and only once' do
    with_modified_env(PII_SHADOW_AUDIT_ENABLED: 'true') do
      lexicon = Llm::PiiNameLexicon
      auditor = Llm::PiiShadowAuditor
      card = create(:contact, account: account, name: 'Test', last_name: 'Синтетиккарточка',
                              identifier: '940720300129', custom_attributes: {
                                Contacts::SharedPhone::CARD_KEY => true, 'iin' => '940720300129', 'birth_date' => '1994-07-20',
                                'medelement_patient_code' => 'synthetic-provider-card', 'medelement_iin' => '940720300129',
                                'medelement_first_name' => 'Test', 'medelement_last_name' => 'Синтетиккарточка'
                              })
      lexicon.clear_cache!
      Llm::PiiFeedbackMetrics.keys(account.id).each { |key| Redis::Alfred.delete(key) }
      lexicon.quarantine_candidate!('Синтетиккарточка', category: :last_name, account_id: account.id)
      expect(lexicon.promote_quarantined_word!('Синтетиккарточка', category: :last_name, account_id: account.id)).to be(false)
      expect(auditor.record_verified_patient!(contact: card, account_id: account.id + 1)).to be(false)
      2.times { resolve(details.merge(last_name: 'Синтетиккарточка')) }
      counts = Llm::PiiFeedbackMetrics.summary(account_id: account.id).fetch(:counters)
      expect(counts['verified_quarantine_promotions']).to eq(1)
      expect(counts['verified_name_promotions']).to eq(2)
      expect(Llm::PiiFeedbackMetrics.summary(account_id: account.id)[:confirmed_false_negatives]).to be_nil
    end
  end
end
