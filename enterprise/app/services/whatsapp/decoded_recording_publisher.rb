require 'digest'
require 'json'

class Whatsapp::DecodedRecordingPublisher
  def initialize(call:, source:, budget:)
    @call = call
    @source = source
    @budget = budget
    @created_blobs = []
  end

  def completed?
    meta = (@call.meta || {})['decoded_recording'] || {}
    meta['state'] == 'completed' && meta['source_sha256'] == @source.digest &&
      meta['decoder_contract'] == Whatsapp::RecordingDecodeBudget::CONTRACT && @call.decoded_recording_manifest.attached?
  end

  def existing_result
    meta = @call.meta.fetch('decoded_recording')
    blob = @call.decoded_recording_manifest.blob
    @budget.mapping!(blob.byte_size)
    data = blob.download
    fail_publication!('derived_manifest_corrupt') unless Digest::SHA256.hexdigest(data) == meta['mapping_sha256']
    mapping = JSON.parse(data)
    @call.with_lock do
      @call.reload
      verify_existing_scope!(blob, meta)
      result(mapping, native_chunks(mapping, meta['mapping_sha256']))
    end
  rescue JSON::ParserError, KeyError
    fail_publication!('derived_manifest_corrupt')
  end

  def perform(mapping:, chunks:)
    data = JSON.generate(mapping)
    @budget.mapping!(data.bytesize)
    @mapping_sha = Digest::SHA256.hexdigest(data)
    staged = chunks.map { |chunk| stage_chunk(chunk) }
    manifest_blob = upload_blob(StringIO.new(data), 'decoded_manifest.json', 'application/json', common_metadata)
    committed = commit!(mapping, staged, manifest_blob)
    committed == :already_completed ? existing_result : committed
  ensure
    @created_blobs.each { |blob| blob.purge_later unless blob.attachments.exists? }
  end

  private

  def verify_existing_scope!(blob, meta)
    same_mapping = @call.decoded_recording_manifest.attached? && @call.decoded_recording_manifest.blob.id == blob.id &&
                   @call.meta.dig('decoded_recording', 'mapping_sha256') == meta['mapping_sha256']
    fail_publication!('stale_source') unless @source.current? && completed? && same_mapping
  end

  def stage_chunk(chunk)
    @budget.check!
    valid = File.size(chunk['path']) == chunk['byte_size'] && Digest::SHA256.file(chunk['path']).hexdigest == chunk['sha256']
    fail_publication!('derived_chunk_corrupt') unless valid
    metadata = common_metadata.merge('decoded_chunk_id' => chunk['id'], 'decoded_chunk_sha256' => chunk['sha256'])
    blob = File.open(chunk['path'], 'rb') { |file| upload_blob(file, "#{chunk['id']}.wav", 'audio/wav', metadata) }
    { chunk: chunk, blob: blob }
  end

  def upload_blob(io, filename, content_type, metadata)
    @budget.check!
    blob = ActiveStorage::Blob.create_and_upload!(io: io, filename: filename, content_type: content_type,
                                                  metadata: metadata.merge('analyzed' => true), identify: false)
    @created_blobs << blob
    blob
  end

  def common_metadata
    { 'decoded_source_sha256' => @source.digest, 'decoded_source_manifest_sha256' => @source.scope[:expected_sha],
      'decoded_contract' => Whatsapp::RecordingDecodeBudget::CONTRACT, 'decoded_mapping_sha256' => @mapping_sha }
  end

  def commit!(mapping, staged, manifest_blob)
    @budget.check!
    @call.with_lock do
      @call.reload
      fail_publication!('stale_source') unless @source.current?
      return :already_completed if completed?

      staged.each { |track| attach_chunk!(track) }
      @call.decoded_recording_manifest.attach(manifest_blob)
      meta = (@call.meta || {}).deep_dup
      meta['decoded_recording'] = { 'state' => 'completed', 'source_sha256' => @source.digest,
                                    'source_manifest_sha256' => @source.scope[:expected_sha],
                                    'decoder_contract' => Whatsapp::RecordingDecodeBudget::CONTRACT,
                                    'mapping_sha256' => @mapping_sha, 'chunk_count' => staged.size, 'completed_at' => Time.current.iso8601 }
      @call.update!(meta: meta)
      detach_superseded_chunks!
      result(mapping, native_chunks(mapping, @mapping_sha))
    end
  end

  def attach_chunk!(track)
    chunk, blob = track.values_at(:chunk, :blob)
    existing = derivation_chunks(@mapping_sha).find { |item| item.metadata['decoded_chunk_id'] == chunk['id'] }
    if existing
      same = existing.byte_size == blob.byte_size && existing.checksum == blob.checksum &&
             existing.metadata.slice(*blob.metadata.keys) == blob.metadata
      fail_publication!('derived_chunk_conflict') unless same
      return
    end
    @call.decoded_recording_chunks.attach(blob)
  end

  # Chunk ids (chunk_000001...) are only unique within one derivation. Chunks of
  # another source, contract or mapping (e.g. another native libopus build) are a
  # superseded derivation, never a conflict with this one.
  def derivation_chunks(mapping_sha)
    @call.decoded_recording_chunks.blobs.select { |blob| derivation?(blob, mapping_sha) }
  end

  def derivation?(blob, mapping_sha)
    blob.metadata.values_at('decoded_source_sha256', 'decoded_contract', 'decoded_mapping_sha256') ==
      [@source.digest, Whatsapp::RecordingDecodeBudget::CONTRACT, mapping_sha]
  end

  # Runs inside the commit transaction: attachment rows of superseded derivations
  # are removed atomically with the new marker and their blobs are purged only
  # after commit (has_many_attached dependent: :purge_later). Original raw
  # captures and the source manifest are separate attachments and never touched.
  def detach_superseded_chunks!
    @call.decoded_recording_chunks_attachments.reload.includes(:blob).each do |attachment|
      attachment.destroy! unless derivation?(attachment.blob, @mapping_sha)
    end
    @call.decoded_recording_chunks_attachments.reset
    @call.decoded_recording_chunks_blobs.reset
  end

  def native_chunks(mapping, mapping_sha)
    chunks = derivation_chunks(mapping_sha)
    mapping.fetch('chunks').map do |chunk|
      matching = chunks.select { |blob| blob.metadata['decoded_chunk_id'] == chunk['id'] }
      fail_publication!('derived_chunk_missing') unless matching.one?
      blob = matching.first
      validate_native_chunk!(blob, chunk)
      chunk.merge('blob_id' => blob.id)
    end
  end

  def validate_native_chunk!(blob, chunk)
    valid = blob.byte_size == chunk['byte_size'] && blob.metadata['decoded_source_sha256'] == @source.digest &&
            blob.metadata['decoded_contract'] == Whatsapp::RecordingDecodeBudget::CONTRACT && blob.metadata['decoded_chunk_sha256'] == chunk['sha256']
    fail_publication!('derived_chunk_corrupt') unless valid
  end

  def result(mapping, chunks)
    { 'state' => 'completed', 'mapping' => mapping, 'chunks' => chunks, 'manifest_blob_id' => @call.decoded_recording_manifest.blob.id }
  end

  def fail_publication!(reason)
    raise Whatsapp::RecordingDecodeError, reason
  end
end
