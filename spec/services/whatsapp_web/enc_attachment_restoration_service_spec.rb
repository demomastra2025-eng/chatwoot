require 'rails_helper'
require 'rake'

RSpec.describe WhatsappWeb::EncAttachmentRestorationService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:channel) { create(:channel_whatsapp_web) }
  let(:contact) { create(:contact, account: channel.account, phone_number: '+15551234567') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: channel.inbox, source_id: '15551234567') }
  let(:conversation) do
    create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:provider_service) { instance_double(WhatsappWeb::Providers::EvolutionService) }

  before do
    allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).and_return(provider_service)
  end

  def encrypt_fixture(plaintext, hkdf_info:)
    raw_key = Random.bytes(32)
    expanded = OpenSSL::KDF.hkdf(raw_key, salt: "\x00".b * 32, info: hkdf_info, length: 112, hash: 'SHA256')
    iv = expanded.byteslice(0, 16)
    cipher = OpenSSL::Cipher.new('AES-256-CBC')
    cipher.encrypt
    cipher.key = expanded.byteslice(16, 32)
    cipher.iv = iv
    ciphertext = cipher.update(plaintext) + cipher.final
    mac = OpenSSL::HMAC.digest('SHA256', expanded.byteslice(48, 32), iv + ciphertext).byteslice(0, 10)
    enc = ciphertext + mac
    {
      media_key: Base64.strict_encode64(raw_key),
      enc_bytes: enc,
      file_sha256: Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(plaintext)),
      file_enc_sha256: Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(enc))
    }
  end

  def create_broken_enc_attachment(source_id:, enc_bytes:, filename: 'blob_123.enc', file_type: :file)
    msg = create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :incoming,
      source_id: source_id,
      content: 'Historical media'
    )
    att = msg.attachments.new(
      account_id: msg.account_id,
      file_type: file_type,
      extension: 'enc',
      file: { io: StringIO.new(enc_bytes), filename: filename, content_type: 'application/octet-stream' }
    )
    att.skip_storage_limit_validation!
    att.save!
    att
  end

  it 'verifies offline decryption in DRY_RUN mode without mutating DB or blobs' do
    plaintext = "PK\x03\x04quarterly-financials-xlsx".b
    fixture = encrypt_fixture(plaintext, hkdf_info: 'WhatsApp Document Keys')
    xlsx_mime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    attachment = create_broken_enc_attachment(source_id: 'HIST-ENC-DRY-1', enc_bytes: fixture[:enc_bytes])

    expect(Down).not_to receive(:download)
    allow(provider_service).to receive(:fetch_message_by_source_id).and_return(
      'key' => { 'id' => 'HIST-ENC-DRY-1', 'remoteJid' => '99887766@lid', 'fromMe' => false },
      'message' => {
        'documentMessage' => {
          'mediaKey' => fixture[:media_key],
          'fileSha256' => fixture[:file_sha256],
          'fileEncSha256' => fixture[:file_enc_sha256],
          'fileName' => 'Q4_Report.xlsx',
          'mimetype' => xlsx_mime
        }
      }
    )

    result = described_class.new(apply: false).perform

    expect(result.mode).to eq('dry_run')
    expect(result.would_restore_count).to eq(1)
    expect(result.restored_count).to eq(0)
    expect(result.items.first).to include(status: 'would_restore', resolution_source: 'stored_blob', new_extension: 'xlsx')
    expect(attachment.reload.extension).to eq('enc')
    expect(attachment.file.filename.to_s).to eq('blob_123.enc')
  end

  it 'backs up raw .enc bytes, restores attachment in-place in APPLY mode, and is idempotent on re-run' do
    plaintext = "OggS\x00\x02restored-voice-note-opus".b
    fixture = encrypt_fixture(plaintext, hkdf_info: 'WhatsApp Audio Keys')
    attachment = create_broken_enc_attachment(source_id: 'HIST-ENC-APPLY-1', enc_bytes: fixture[:enc_bytes], file_type: :file)
    backup_dir = Dir.mktmpdir('waweb-enc-backup-spec')

    allow(provider_service).to receive(:fetch_message_by_source_id).and_return(
      'key' => { 'id' => 'HIST-ENC-APPLY-1', 'remoteJid' => '99887766@lid', 'fromMe' => false },
      'message' => {
        'audioMessage' => {
          'mediaKey' => fixture[:media_key],
          'fileSha256' => fixture[:file_sha256],
          'mimetype' => 'audio/ogg; codecs=opus'
        }
      }
    )

    result = described_class.new(apply: true, backup_dir: backup_dir).perform
    expect(result.restored_count).to eq(1)
    expect(File.binread(File.join(backup_dir, "attachment_#{attachment.id}.enc"))).to eq(fixture[:enc_bytes])
    expect(File.exist?(File.join(backup_dir, "attachment_#{attachment.id}.json"))).to be(true)

    attachment.reload
    expect(attachment.extension).to eq('ogg')
    expect(attachment.file_type).to eq('audio')
    expect(attachment.file.content_type).to eq('audio/ogg')

    rerun = described_class.new(apply: true, attachment_ids: [attachment.id], backup_dir: backup_dir).perform
    expect(rerun.restored_count).to eq(0)
  ensure
    FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
  end

  it 'refuses to overwrite an attached .enc blob when its original bytes could not be read for backup' do
    fixture = encrypt_fixture('%PDF-1.7-guard-test'.b, hkdf_info: 'WhatsApp Document Keys')
    attachment = create_broken_enc_attachment(source_id: 'HIST-GUARD-1', enc_bytes: fixture[:enc_bytes])
    backup_dir = Dir.mktmpdir('waweb-guard-backup-spec')

    allow(provider_service).to receive(:fetch_message_by_source_id).and_return(
      'key' => { 'id' => 'HIST-GUARD-1', 'fromMe' => false },
      'message' => { 'documentMessage' => { 'fileName' => 'guarded.pdf', 'mimetype' => 'application/pdf' } }
    )
    allow(provider_service).to receive(:fetch_message_media).and_return(
      base64: Base64.strict_encode64('%PDF-1.7-guard-test'),
      fileName: 'guarded.pdf',
      mimetype: 'application/pdf'
    )

    service = described_class.new(apply: true, attachment_ids: [attachment.id], backup_dir: backup_dir)
    allow(service).to receive(:read_stored_blob_bytes).and_return(nil)

    result = service.perform

    expect(result.failed_count).to eq(1)
    expect(result.restored_count).to eq(0)
    expect(result.items.first[:reason]).to include('RestorationError')
    expect(attachment.reload.extension).to eq('enc')
    expect(attachment.file.filename.to_s).to eq('blob_123.enc')
  ensure
    FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
  end

  it 'keeps extension and original .enc blob intact atomically if save! fails, and tolerates send_update_event errors' do
    plaintext = '%PDF-1.7-atomic-and-event-safe'.b
    fixture = encrypt_fixture(plaintext, hkdf_info: 'WhatsApp Document Keys')
    attachment = create_broken_enc_attachment(source_id: 'HIST-ATOMIC-1', enc_bytes: fixture[:enc_bytes])
    backup_dir = Dir.mktmpdir('waweb-atomic-backup-spec')

    allow(provider_service).to receive(:fetch_message_by_source_id).and_return(
      'key' => { 'id' => 'HIST-ATOMIC-1', 'fromMe' => false },
      'message' => { 'documentMessage' => { 'mediaKey' => fixture[:media_key], 'fileName' => 'atomic.pdf', 'mimetype' => 'application/pdf' } }
    )

    service_fail = described_class.new(apply: true, attachment_ids: [attachment.id], backup_dir: backup_dir)
    allow(service_fail).to receive(:candidate_attachments)
      .and_return([attachment].tap { |arr| arr.define_singleton_method(:find_each) { |&blk| each(&blk) } })
    allow(attachment).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)

    failed_res = service_fail.perform
    expect(failed_res.failed_count).to eq(1)
    expect(attachment.reload.extension).to eq('enc')
    expect(attachment.file.filename.to_s).to eq('blob_123.enc')

    fresh_attachment = Attachment.find(attachment.id)
    allow(fresh_attachment.message).to receive(:reload).and_return(fresh_attachment.message)
    allow(fresh_attachment.message).to receive(:send_update_event).and_raise(StandardError, 'event bus offline')
    service_ok = described_class.new(apply: true, attachment_ids: [fresh_attachment.id], backup_dir: backup_dir)
    allow(service_ok).to receive(:candidate_attachments)
      .and_return([fresh_attachment].tap { |arr| arr.define_singleton_method(:find_each) { |&blk| each(&blk) } })

    ok_res = service_ok.perform
    expect(ok_res.restored_count).to eq(1)
    expect(fresh_attachment.reload.extension).to eq('pdf')
  ensure
    FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
  end

  def pg_base_url_from_active_record
    ar_cfg = ActiveRecord::Base.connection_db_config.configuration_hash
    format(
      'postgresql://%<user>s:%<pass>s@%<host>s:%<port>s/%<db>s',
      user: URI.encode_www_form_component(ar_cfg[:username].to_s),
      pass: URI.encode_www_form_component(ar_cfg[:password].to_s),
      host: ar_cfg[:host] || '127.0.0.1',
      port: ar_cfg[:port] || 5432,
      db: ar_cfg[:database]
    )
  end

  def seed_committed_evolution_schema!(base_url, instance_name:, source_id:, message_payload:)
    conn = PG.connect(base_url)
    conn.exec('DROP SCHEMA IF EXISTS evolution_spec_tmp CASCADE')
    conn.exec('CREATE SCHEMA evolution_spec_tmp')
    conn.exec('CREATE TABLE evolution_spec_tmp."Instance" ("id" text PRIMARY KEY, "name" text)')
    conn.exec(
      'CREATE TABLE evolution_spec_tmp."Message" ("id" text PRIMARY KEY, "key" jsonb, "message" jsonb, ' \
      '"messageType" text, "messageTimestamp" integer, "instanceId" text)'
    )
    conn.exec_params('INSERT INTO evolution_spec_tmp."Instance" ("id", "name") VALUES ($1, $2)', ['inst-1', instance_name])
    key_json = { id: source_id, remoteJid: '777888@lid', fromMe: false }.to_json
    conn.exec_params(
      'INSERT INTO evolution_spec_tmp."Message" ("id", "key", "message", "messageType", "messageTimestamp", "instanceId") ' \
      'VALUES ($1, $2::jsonb, $3::jsonb, $4, $5, $6)',
      ['row-1', key_json, message_payload.to_json, 'documentMessage', 1_730_000_000, 'inst-1']
    )
  ensure
    conn&.close
  end

  def drop_committed_evolution_schema!(base_url)
    conn = PG.connect(base_url)
    conn.exec('DROP SCHEMA IF EXISTS evolution_spec_tmp CASCADE')
  ensure
    conn&.close
  end

  it 'falls back to read-only Evolution Postgres lookup with Prisma ?schema= URL when HTTP lookup fails' do
    plaintext = "\x00\x00\x00\x18ftypmp42doc-video-bytes".b
    fixture = encrypt_fixture(plaintext, hkdf_info: 'WhatsApp Document Keys')
    attachment = create_broken_enc_attachment(source_id: 'HIST-SQL-DOCVID-1', enc_bytes: fixture[:enc_bytes])
    backup_dir = Dir.mktmpdir('waweb-sql-backup-spec')
    base_url = pg_base_url_from_active_record
    seed_committed_evolution_schema!(
      base_url,
      instance_name: channel.instance_name,
      source_id: 'HIST-SQL-DOCVID-1',
      message_payload: { documentMessage: { mediaKey: fixture[:media_key], fileName: 'clip_as_doc.mp4', mimetype: 'video/mp4' } }
    )

    allow(provider_service).to receive(:fetch_message_by_source_id).and_return(nil)
    result = described_class.new(apply: true, backup_dir: backup_dir, evolution_database_url: "#{base_url}?schema=evolution_spec_tmp").perform

    expect(result.restored_count).to eq(1)
    expect(attachment.reload.extension).to eq('mp4')
    expect(attachment.file_type).to eq('file')
    expect(attachment.file.blob.open { |tf| File.binread(tf.path) }).to eq(plaintext)
  ensure
    drop_committed_evolution_schema!(base_url) if base_url
    FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
  end

  it 'runs via rake whatsapp_web:restore_enc_attachments in DRY_RUN and APPLY modes' do
    Rails.application.load_tasks unless Rake::Task.task_defined?('whatsapp_web:restore_enc_attachments')
    plaintext = '%PDF-1.7-rake-restored'.b
    fixture = encrypt_fixture(plaintext, hkdf_info: 'WhatsApp Document Keys')
    attachment = create_broken_enc_attachment(source_id: 'HIST-RAKE-1', enc_bytes: fixture[:enc_bytes])
    backup_dir = Dir.mktmpdir('waweb-rake-backup-spec')

    allow(provider_service).to receive(:fetch_message_by_source_id).and_return(
      'key' => { 'id' => 'HIST-RAKE-1', 'fromMe' => false },
      'message' => { 'documentMessage' => { 'mediaKey' => fixture[:media_key], 'fileName' => 'scan.pdf', 'mimetype' => 'application/pdf' } }
    )

    task = Rake::Task['whatsapp_web:restore_enc_attachments']
    with_modified_env('DRY_RUN' => '1', 'APPLY' => nil, 'ATTACHMENT_IDS' => attachment.id.to_s, 'BACKUP_DIR' => backup_dir) do
      task.reenable
      expect { task.invoke }.to output(/"mode": "dry_run"/).to_stdout
    end
    expect(attachment.reload.extension).to eq('enc')

    with_modified_env('DRY_RUN' => nil, 'APPLY' => '1', 'ATTACHMENT_IDS' => attachment.id.to_s, 'BACKUP_DIR' => backup_dir) do
      task.reenable
      expect { task.invoke }.to output(/"restored_count": 1/).to_stdout
    end
    expect(attachment.reload.extension).to eq('pdf')
  ensure
    FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
  end
end
