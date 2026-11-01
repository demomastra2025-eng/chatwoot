# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Compliance::SubjectErasureService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Д-р Сейтказиев') }
  let(:patient_iin) { '920815300456' }
  let(:patient_phone) { '+77027771122' }
  let(:patient_code) { 'ME-PAT-994411' }
  let(:recordings_dir) { Storage::RecordingPaths.root.join('voice-recordings', 'telephony', account.id.to_s).to_s }

  let!(:contact) do
    create(
      :contact,
      account: account,
      name: 'Дамир',
      last_name: 'Касымов',
      phone_number: patient_phone,
      email: 'damir.kasymov@example.kz',
      identifier: patient_iin,
      custom_attributes: {
        'iin' => patient_iin,
        'medelement_patient_code' => patient_code
      }
    )
  end

  let!(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let!(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact, content: 'Удалите мои данные')
  end
  let!(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      client_name: 'Дамир Касымов',
      client_first_name: 'Дамир',
      client_last_name: 'Касымов',
      client_phone: patient_phone,
      client_identifier: patient_iin,
      service_amount: 15_000,
      starts_at: 1.day.from_now.change(hour: 10, min: 0),
      ends_at: 1.day.from_now.change(hour: 10, min: 30),
      custom_attributes: { 'medelement_patient_code' => patient_code, 'iin' => patient_iin }
    )
  end

  before do
    allow(Rails.configuration.active_storage).to receive(:service).and_return(:s3_compatible)
  end

  after do
    FileUtils.rm_rf(recordings_dir)
  end

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it 'cascades erasure with conversation FKs & Redis vaults, blocks new-code MedElement resurrection, and replays chronologically' do
    ConversationStatusTransition.create!(
      account: account,
      conversation: conversation,
      from_status: 'pending',
      to_status: 'open',
      source: 'manual'
    )

    pii_token = nil
    Llm::IinTokenVault.with_scope(account_id: account.id, scope_id: "conv:#{conversation.id}") do
      Llm::IinTokenVault.tokenize(patient_iin)
    end
    Llm::PiiSessionPseudonymizer.with_scope(account_id: account.id, scope_id: "conv:#{conversation.id}") do
      pii_token = Llm::PiiSessionPseudonymizer.tokenize_name('Дамир Касымов')
    end

    storage_key = "voice-recordings/telephony/#{account.id}/erase-me.mp3"
    FileUtils.mkdir_p(recordings_dir)
    tmp_mp3 = File.join(recordings_dir, 'erase-me.mp3')
    File.binwrite(tmp_mp3, 'VOICE-PII-AUDIO' * 50)
    Storage::VoiceRecordingRemoteStorage.offload_file!(storage_key, tmp_mp3, content_type: 'audio/mpeg')

    # Conversation-only call session (contact_id: nil) must also be scrubbed and its S3 recording purged (P1-9)
    call_session = Telephony::CallSession.create!(
      account: account,
      provider: 'sipuni',
      contact: nil,
      conversation: conversation,
      external_call_ref: "call-#{SecureRandom.hex(5)}",
      direction: 'inbound',
      status: 'completed',
      from_number: patient_phone,
      to_number: '+77270001122',
      recording_ref: storage_key,
      metadata: { 'recording' => { 'storage_provider' => 's3', 'storage_key' => storage_key, 'byte_size' => 750 } }
    )

    certificate = described_class.new(
      account: account,
      contact: contact,
      reason: 'patient_withdrawal_of_consent'
    ).perform!

    expect(Contact.exists?(contact.id)).to be(false)
    expect(Conversation.exists?(conversation.id)).to be(false)
    expect(Message.exists?(message.id)).to be(false)
    expect(Storage::VoiceRecordingRemoteStorage.exist?(storage_key)).to be(false)

    # Fresh scope reading Redis (empty memory) must find zero leftover PII tokens after erasure
    Llm::PiiSessionPseudonymizer.with_scope(account_id: account.id, scope_id: "conv:#{conversation.id}") do
      expect(Llm::PiiSessionPseudonymizer.unmask_customer_text(pii_token)).to eq('[СКРЫТО]')
    end

    call_session.reload
    expect(call_session.contact_id).to be_nil
    expect(call_session.conversation_id).to be_nil
    expect(call_session.recording_ref).to be_nil
    expect(call_session.from_number.to_s).not_to include('7027771122')

    appointment.reload
    expect(appointment.contact_id).to be_nil
    expect(appointment.conversation_id).to be_nil
    expect(appointment.client_name).to eq('[УДАЛЕНО]')
    expect(appointment.client_phone).to be_nil
    expect(appointment.client_identifier).to be_nil
    expect(appointment.custom_attributes['medelement_patient_code']).to be_nil
    expect(appointment.service_amount).to eq(15_000)

    cert_json = JSON.generate(certificate)
    [patient_phone, '7027771122', patient_iin, 'Дамир', 'Касымов', 'damir.kasymov', patient_code].each do |raw_pii|
      expect(cert_json).not_to include(raw_pii)
    end
    expect(certificate[:remote_ledger_synced]).to be(true)

    remote_payload = Compliance::TombstoneRemoteLedger.download_json(certificate[:remote_ledger_key])
    expect(remote_payload['certificate_uid']).to eq(certificate[:certificate_uid])
    expect(JSON.generate(remote_payload)).not_to include(patient_iin)
    expect(JSON.generate(remote_payload)).not_to include('7027771122')

    fake_client = instance_double(
      Integrations::Medelement::Client,
      get_patient: {
        'PATIENT_CODE' => 'NEW-CODE-AFTER-EDIT',
        'IIN' => patient_iin,
        'NAME' => 'Дамир',
        'LASTNAME' => 'Касымов',
        'MOBILE_PHONE' => patient_phone
      }
    )
    resolver = Integrations::Medelement::ContactResolverService.new(account: account, client: fake_client)
    expect(resolver.sync_patient!(patient_code)).to be_nil
    expect(resolver.sync_patient!('NEW-CODE-AFTER-EDIT')).to be_nil
    expect(
      Compliance::DeletedSubjectTombstone.blocked?(
        account_id: account.id,
        identifiers: { medelement_patient_code: 'NEW-CODE-AFTER-EDIT' }
      )
    ).to be(true)
    expect(account.contacts.count).to eq(0)

    # Chronological replay test: erasure(T1) -> revocation(T2) -> erasure(T3) must leave subject BLOCKED!
    t1 = 3.hours.ago.utc.iso8601
    t2 = 2.hours.ago.utc.iso8601
    t3 = 1.hour.ago.utc.iso8601
    Compliance::DeletedSubjectTombstone.where(account_id: account.id).delete_all
    resurrected = create(:contact, account: account, name: 'Дамир Воскресший', phone_number: patient_phone)

    events = [
      remote_payload.merge('erased_at' => t1),
      { 'type' => 'revocation', 'revoked_at' => t2, 'entries' => remote_payload['entries'] },
      remote_payload.merge('erased_at' => t3, 'certificate_uid' => 'ACT-PDN-NEWER')
    ]
    replay = Compliance::TombstoneReplayService.new(account: account, records: events).perform!
    expect(replay[:replayed_erasures]).to eq(2)
    expect(replay[:purged_resurrected_contacts]).to eq(1)
    expect(Contact.exists?(resurrected.id)).to be(false)
    expect(Compliance::DeletedSubjectTombstone.blocked?(account_id: account.id, identifiers: { phone: patient_phone })).to be(true)

    revoked_ids = {
      phone: patient_phone, iin: patient_iin, email: 'damir.kasymov@example.kz',
      medelement_patient_code: [patient_code, 'NEW-CODE-AFTER-EDIT']
    }
    revoked = Compliance::DeletedSubjectTombstone.revoke_for!(account_id: account.id, identifiers: revoked_ids)
    expect(revoked).to be >= 4
    expect(Compliance::DeletedSubjectTombstone.blocked?(account_id: account.id, identifiers: { phone: patient_phone })).to be(false)
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations

  it 'synchronously purges ActiveStorage voice recordings attached to WhatsApp and Telegram Personal Call rows' do
    tg_channel = create(:channel_telegram_personal, account: account)
    call = Call.create!(
      provider: :telegram_personal,
      account: account,
      inbox: tg_channel.inbox,
      conversation: conversation,
      contact: contact,
      provider_call_id: 'tg-erase-call-1',
      direction: :incoming,
      status: 'completed'
    )
    call.recording.attach(io: StringIO.new("OggS#{'z' * 512}"), filename: 'tg_erase.ogg', content_type: 'audio/ogg')
    blob_id = call.recording.blob.id

    cert = described_class.new(account: account, contact: contact, reason: 'subject_request').perform!

    expect(cert.dig(:erased_counts, :call_recordings_purged)).to be >= 1
    expect(Call.exists?(call.id)).to be(false)
    expect(ActiveStorage::Attachment.where(record_type: 'Call', record_id: call.id)).to be_empty
    expect(ActiveStorage::Blob.exists?(blob_id)).to be(false)
  end
end
