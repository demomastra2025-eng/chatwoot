# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
namespace :telephony do
  desc 'Compress uncompressed WAV call recordings to MP3 64k stereo'
  task :compress_recordings, %i[account_id dry_run limit] => :environment do |_t, args|
    account_id = args[:account_id].presence&.to_i
    dry_run = args[:dry_run].to_s == 'true'
    limit = (args[:limit].presence || 100).to_i

    scope = Telephony::CallSession.where.not(recording_ref: [nil, ''])
                                  .where('recording_ref ILIKE ? OR recording_ref ILIKE ?', '%.wav', '%.wave')
    scope = scope.where(account_id: account_id) if account_id.present?

    total_pending = scope.count
    puts "Found #{total_pending} uncompressed call recordings (processing up to #{limit})..."
    puts "Dry run mode: #{dry_run}" if dry_run

    total_orig = 0
    total_comp = 0
    count = 0

    storage_root = Rails.root.join('storage')

    scope.limit(limit).find_each do |session|
      file_path = storage_root.join(session.recording_ref)
      next unless File.file?(file_path)

      orig_size = File.size(file_path)
      total_orig += orig_size

      if dry_run
        puts "[DRY RUN] #{session.id}: #{session.recording_ref} (#{ActiveSupport::NumberHelper.number_to_human_size(orig_size)})"
      else
        result = Telephony::RecordingCompressionService.compress(call_session: session)
        if result[:success]
          count += 1
          total_comp += result[:compressed_bytes]
          saved = result[:freed_bytes]
          puts "[OK] #{session.id}: #{result[:new_storage_key]} - freed #{ActiveSupport::NumberHelper.number_to_human_size(saved)}"
        else
          puts "[FAIL] #{session.id}: #{result[:error]}"
        end
      end
    end

    freed = total_orig - total_comp
    puts "\n--- COMPRESSION SUMMARY ---"
    puts "Processed: #{count} recordings"
    puts "Original volume: #{ActiveSupport::NumberHelper.number_to_human_size(total_orig)}"
    puts "Compressed volume: #{ActiveSupport::NumberHelper.number_to_human_size(total_comp)}"
    puts "Total freed: #{ActiveSupport::NumberHelper.number_to_human_size(freed)}"
  end
end
# rubocop:enable Metrics/BlockLength
