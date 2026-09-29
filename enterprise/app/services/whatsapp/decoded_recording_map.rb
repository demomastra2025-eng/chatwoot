class Whatsapp::DecodedRecordingMap
  def initialize(mapping:)
    @mapping = mapping
    valid = mapping['version'] == 1 && mapping['state'] == 'completed' &&
            mapping['decoder_contract'] == Whatsapp::RecordingDecodeBudget::CONTRACT && mapping['sample_rate'] == 48_000
    raise Whatsapp::RecordingDecodeError, 'unsupported_decoded_mapping' unless valid
  end

  # Missing captured input is not a verified speech interval. The next STT
  # contract must retain this rejection rather than hiding the gap mask.
  def range_ns(chunk_id:, start_sample:, end_sample:)
    chunk = @mapping.fetch('chunks').find { |item| item['id'] == chunk_id }
    validate_range!(chunk, start_sample, end_sample)
    validate_gap!(chunk, start_sample, end_sample)
    epoch = @mapping.fetch('epochs').find { |item| item['id'] == chunk['epoch_id'] }
    raise Whatsapp::RecordingDecodeError, 'invalid_decoded_epoch' unless epoch

    [start_sample, end_sample].map do |sample|
      epoch['origin_offset_ns'] + ((chunk['epoch_start_sample'] + sample) * 1_000_000_000 / @mapping['sample_rate'])
    end
  end

  private

  def validate_range!(chunk, first, last)
    valid = chunk && [first, last].all?(Integer) && first >= 0 && first < last && last <= chunk['sample_count']
    raise Whatsapp::RecordingDecodeError, 'invalid_decoded_range' unless valid
  end

  def validate_gap!(chunk, first, last)
    overlap = chunk.fetch('gap_ranges').any? { |gap| first < gap['end_sample'] && last > gap['start_sample'] }
    raise Whatsapp::RecordingDecodeError, 'decoded_range_intersects_gap' if overlap
  end
end
