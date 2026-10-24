# What one stale status reconciliation run did, or in a dry run would do. Counts and appointment ids only: no patient data.
class Integrations::Medelement::StaleStatusReport
  NOT_FOUND_SAMPLE_LIMIT = 200

  attr_reader :dry_run, :days, :examined, :changed, :unchanged, :not_found, :out_of_scope, :skipped, :errors,
              :transitions, :not_found_appointment_ids, :skipped_reasons, :error_codes
  attr_accessor :aborted, :last_id, :remaining

  def initialize(dry_run:, days:)
    @dry_run = dry_run
    @days = days
    @examined = @changed = @unchanged = @not_found = @out_of_scope = @skipped = @errors = 0
    @transitions = Hash.new { |hash, status| hash[status] = Hash.new(0) }
    @not_found_appointment_ids = []
    @skipped_reasons = Hash.new(0)
    @error_codes = Hash.new(0)
  end

  def examine!
    @examined += 1
  end

  # The old status of the appointment and the status MedElement gives it (the status it now has, in a real run).
  def transition!(from, to)
    @transitions[from][to] += 1
    from == to ? @unchanged += 1 : @changed += 1
  end

  def not_found!(appointment_id)
    @not_found += 1
    @not_found_appointment_ids << appointment_id if @not_found_appointment_ids.size < NOT_FOUND_SAMPLE_LIMIT
  end

  def out_of_scope!
    @out_of_scope += 1
  end

  def skipped!(reason)
    @skipped += 1
    @skipped_reasons[reason] += 1
  end

  def error!(code)
    @errors += 1
    @error_codes[code] += 1
  end

  def to_h
    {
      dry_run: dry_run, days: days, examined: examined, changed: changed, unchanged: unchanged, not_found: not_found,
      out_of_scope: out_of_scope, skipped: skipped, errors: errors, transitions: transitions.transform_values(&:to_h),
      not_found_appointment_ids: not_found_appointment_ids, skipped_reasons: skipped_reasons.to_h,
      error_codes: error_codes.to_h, last_id: last_id, remaining: remaining, aborted: aborted
    }
  end

  # One line per old status and provider status, then the outcomes that did not lead to a status.
  def summary_lines
    lines = transitions.sort.flat_map do |from, targets|
      targets.sort.map { |to, count| "  #{from} -> #{to}: #{count}" }
    end
    lines + outcome_lines
  end

  private

  def outcome_lines
    lines = []
    lines << "  not found at MedElement (kept, not deleted): #{not_found} appointment ids #{not_found_appointment_ids.inspect}" if not_found.positive?
    lines << "  out of scope (specialist or cabinet not mapped in OneLink): #{out_of_scope}" if out_of_scope.positive?
    lines << "  skipped: #{skipped_reasons.to_h.inspect}" if skipped.positive?
    lines << "  provider errors: #{error_codes.to_h.inspect}" if errors.positive?
    lines
  end
end
