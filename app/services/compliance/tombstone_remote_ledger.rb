# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require 'stringio'

# Persists PII-free HMAC tombstones to ActiveStorage (ps.kz S3 in production)
# outside PostgreSQL dumps so deleted subjects cannot resurrect after a DB restore.
module Compliance::TombstoneRemoteLedger
  KEY_PREFIX = 'compliance/tombstones'

  module_function

  def erasure_key(account_id, certificate_uid)
    "#{KEY_PREFIX}/#{account_id.to_i}/erasures/#{certificate_uid}.json"
  end

  def revocation_key(account_id, revocation_uid)
    "#{KEY_PREFIX}/#{account_id.to_i}/revocations/#{revocation_uid}.json"
  end

  # rubocop:disable Metrics/ParameterLists
  def write_erasure!(account_id:, certificate_uid:, entries:, erased_at:, reason:, metadata: {})
    key = erasure_key(account_id, certificate_uid)
    payload = {
      version: 1,
      type: 'erasure',
      account_id: account_id.to_i,
      certificate_uid: certificate_uid.to_s,
      erased_at: erased_at.utc.iso8601,
      reason: reason.to_s,
      entries: entries.map { |e| { 'kind' => (e[:kind] || e['kind']).to_s, 'hmac' => (e[:hmac] || e['hmac']).to_s } },
      metadata: metadata.to_h
    }
    upload_json!(key, payload)
    key
  end
  # rubocop:enable Metrics/ParameterLists

  def write_revocation!(account_id:, entries:, revoked_at: Time.current)
    uid = "REV-#{revoked_at.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(6).upcase}"
    key = revocation_key(account_id, uid)
    payload = {
      version: 1,
      type: 'revocation',
      account_id: account_id.to_i,
      revocation_uid: uid,
      revoked_at: revoked_at.utc.iso8601,
      entries: entries.map { |e| { 'kind' => (e[:kind] || e['kind']).to_s, 'hmac' => (e[:hmac] || e['hmac']).to_s } }
    }
    upload_json!(key, payload)
    key
  rescue StandardError => e
    Rails.logger.warn("[Compliance::TombstoneRemoteLedger] write_revocation failed account_id=#{account_id}: #{e.class}: #{e.message}")
    nil
  end

  def list_account_records(account_id)
    prefix = "#{KEY_PREFIX}/#{account_id.to_i}/"
    keys = list_keys(prefix)
    keys.filter_map { |key| download_json(key) }
  end

  def upload_json!(key, payload)
    body = JSON.generate(payload)
    checksum = Digest::MD5.base64digest(body)
    service.upload(key, StringIO.new(body), checksum: checksum, content_type: 'application/json')
    true
  end

  def download_json(key)
    raw = service.download(key)
    JSON.parse(raw)
  rescue StandardError
    nil
  end

  def list_keys(prefix)
    svc = service
    if svc.class.name.include?('S3Service') && svc.respond_to?(:bucket)
      svc.bucket.objects(prefix: prefix).map(&:key)
    elsif svc.respond_to?(:root)
      list_disk_keys(svc, prefix)
    else
      []
    end
  rescue StandardError => e
    Rails.logger.warn("[Compliance::TombstoneRemoteLedger] list_keys failed prefix=#{prefix}: #{e.class}")
    []
  end

  def list_disk_keys(svc, prefix)
    # ActiveStorage::Service::DiskService stores files at path_for(key); for plain prefix directories or direct reads:
    root = Pathname.new(svc.root)
    direct_dir = root.join(prefix)
    keys = []
    if direct_dir.exist?
      Dir.glob(direct_dir.join('**', '*.json')).each do |full|
        keys << Pathname.new(full).relative_path_from(root).to_s.tr('\\', '/')
      end
    end
    keys
  end

  def service
    ActiveStorage::Blob.service
  end

  private_class_method :upload_json!, :list_disk_keys, :service
end
