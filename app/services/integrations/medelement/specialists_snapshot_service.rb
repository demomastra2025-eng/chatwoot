class Integrations::Medelement::SpecialistsSnapshotService
  class IncompleteSnapshotError < StandardError; end

  STABILITY_READS = 2

  def initialize(client:)
    @client = client
  end

  def perform
    snapshots = Array.new(STABILITY_READS) { validated_snapshot }
    fingerprints = snapshots.map { |rows| fingerprint(rows) }
    raise_incomplete!('Medelement specialists snapshot changed between reads') unless fingerprints.uniq.one?

    snapshots.last
  end

  private

  attr_reader :client

  def validated_snapshot
    rows = Array(client.specialists)
    raise_incomplete!('Medelement specialists snapshot is empty') if rows.empty?

    codes = rows.map { |row| row.to_h.with_indifferent_access['specialistCode'].to_s.presence }
    raise_incomplete!('Medelement specialists snapshot contains a row without specialistCode') if codes.any?(&:nil?)
    raise_incomplete!('Medelement specialists snapshot contains duplicate specialistCode values') if codes.uniq.size != codes.size

    rows
  end

  def fingerprint(rows)
    rows.map { |row| row.to_h.with_indifferent_access['specialistCode'].to_s }.sort
  end

  def raise_incomplete!(message)
    raise IncompleteSnapshotError, message
  end
end
