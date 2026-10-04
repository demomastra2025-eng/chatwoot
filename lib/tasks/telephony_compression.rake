# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
namespace :telephony do
  desc 'Compress uncompressed WAV call recordings to MP3 64k stereo. ' \
       'Dry run by default and account-scoped: rake "telephony:compress_recordings[ACCOUNT_ID,false,LIMIT,AFTER_ID]" opts in ' \
       '(original WAV is retained for 30 days).'
  task :compress_recordings, %i[account_id dry_run limit after_id] => :environment do |_t, args|
    account_id = args[:account_id].presence&.to_i
    abort 'ACCOUNT_ID is required for historical compression batches' unless account_id&.positive?

    dry_run = args[:dry_run].to_s.downcase != 'false'
    limit = (args[:limit].presence || 50).to_i.clamp(1, Telephony::CompressRecordingsJob::DEFAULT_BATCH_SIZE)
    after_id = (args[:after_id].presence || 0).to_i.clamp(0, (2**63) - 1)

    scope = Telephony::CallSession.where(account_id: account_id).where.not(recording_ref: [nil, ''])
                                  .where('recording_ref ILIKE ? OR recording_ref ILIKE ?', '%.wav', '%.wave')
                                  .where('id > ?', after_id)

    total_pending = scope.count
    batch = scope.order(:id).limit(limit).to_a
    puts "Found #{total_pending} uncompressed call recordings after id #{after_id} (processing up to #{limit})..."
    if dry_run
      puts 'DRY RUN: nothing is changed. Pass dry_run=false as the second argument to compress for real.'
    else
      puts 'LIVE RUN: original WAV files remain available for 30 days.'
    end

    total_orig = 0
    total_comp = 0
    count = 0

    batch.each do |session|
      file_path = Storage::RecordingPaths.resolve(session.recording_ref, account_id: session.account_id)
      next unless file_path

      orig_size = File.size(file_path)
      total_orig += orig_size

      if dry_run
        puts "[DRY RUN] call session #{session.id} (#{ActiveSupport::NumberHelper.number_to_human_size(orig_size)})"
        next
      end

      result = Telephony::RecordingCompressionService.compress(call_session: session)
      if result[:success]
        count += 1
        total_comp += result[:compressed_bytes]
        puts "[OK] call session #{session.id}: converted; original retained for 30 days"
      elsif result[:skipped]
        total_orig -= orig_size
        puts "[SKIP] #{session.id}: #{result[:reason]}"
      else
        total_orig -= orig_size
        puts "[FAIL] #{session.id}: #{result[:error]}"
      end
    end

    puts "\n--- COMPRESSION SUMMARY#{' (DRY RUN)' if dry_run} ---"
    puts "Recordings #{dry_run ? 'that would be processed' : 'processed'}: #{dry_run ? total_pending.clamp(0, limit) : count}"
    puts "Resume after call session id: #{batch.last&.id || after_id}"
    puts "Original volume: #{ActiveSupport::NumberHelper.number_to_human_size(total_orig)}"
    unless dry_run
      puts "Compressed volume: #{ActiveSupport::NumberHelper.number_to_human_size(total_comp)}"
      puts "Originals retained for 30 days; no physical space is released until retention expires."
    end
  end
end
# rubocop:enable Metrics/BlockLength
