# frozen_string_literal: true

require 'zlib'

# Serializes mutations of a tenant recording across web and job workers.
module Storage::RecordingLock
  LOCK_NAMESPACE = 1_398_031_876

  module_function

  def synchronize(account_id:, storage_keys:, &)
    keys = Array(storage_keys).compact.reject(&:blank?).map do |key|
      Storage::RecordingPaths.canonical_lock_identity(key, account_id: account_id)
    end.uniq.sort
    synchronize_keys(account_id.to_i, keys, 0, &)
  end

  def synchronize_keys(account_id, keys, index, &)
    return yield if index >= keys.length

    lock_id = Zlib.crc32("#{account_id}:#{keys[index]}") & 0x7fff_ffff
    connection = ActiveRecord::Base.connection
    namespace_sql = connection.quote(Integer(LOCK_NAMESPACE))
    lock_id_sql = connection.quote(Integer(lock_id))
    connection.select_value("SELECT pg_advisory_lock(#{namespace_sql}, #{lock_id_sql})")
    begin
      synchronize_keys(account_id, keys, index + 1, &)
    ensure
      connection.select_value("SELECT pg_advisory_unlock(#{namespace_sql}, #{lock_id_sql})")
    end
  end
  private_class_method :synchronize_keys
end
