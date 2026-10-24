# What one stale status reconciliation run did, or in a dry run would do. Counts and appointment ids only: no patient data.
class Integrations::Medelement::StaleStatusReport
  NOT_FOUND_SAMPLE_LIMIT = 200
  LOG_KEYS = %i[dry_run days examined changed unchanged automation_matches not_found out_of_scope out_of_scope_reasons skipped
                errors remaining aborted].freeze

  attr_reader :dry_run, :days, :examined, :changed, :unchanged, :not_found, :out_of_scope, :skipped, :errors,
              :transitions, :not_found_appointment_ids, :skipped_reasons, :error_codes, :automation_matches, :out_of_scope_reasons
  attr_accessor :aborted, :last_id, :remaining, :automation_rules

  def initialize(dry_run:, days:)
    @dry_run = dry_run
    @days = days
    @examined = @changed = @unchanged = @not_found = @out_of_scope = @skipped = @errors = @automation_matches = 0
    @transitions = Hash.new { |hash, status| hash[status] = Hash.new(0) }
    @not_found_appointment_ids = []
    @skipped_reasons = Hash.new(0)
    @out_of_scope_reasons = Hash.new(0)
    @error_codes = Hash.new(0)
    @automation_rules = {}
  end

  def examine!
    @examined += 1
  end

  # The old status of the appointment and the status MedElement gives it (the status it now has, in a real run).
  def transition!(from, to)
    @transitions[from][to] += 1
    from == to ? @unchanged += 1 : @changed += 1
  end

  # A status change that an active automation rule listens for (by event only: its conditions are not evaluated).
  # Reconciled changes fire no rules, so in a real run these are the ones that were held back.
  def automation_match!
    @automation_matches += 1
  end

  def not_found!(appointment_id)
    @not_found += 1
    @not_found_appointment_ids << appointment_id if @not_found_appointment_ids.size < NOT_FOUND_SAMPLE_LIMIT
  end

  # reason: why the import refuses the reception (see ReceptionsSyncService::OUT_OF_SCOPE_REASONS).
  def out_of_scope!(reason = nil)
    @out_of_scope += 1
    @out_of_scope_reasons[reason || :unspecified] += 1
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
      out_of_scope: out_of_scope, out_of_scope_reasons: out_of_scope_reasons.to_h, skipped: skipped, errors: errors,
      transitions: transitions.transform_values(&:to_h),
      automation_matches: automation_matches, automation_rules: automation_rules,
      not_found_appointment_ids: not_found_appointment_ids, skipped_reasons: skipped_reasons.to_h,
      error_codes: error_codes.to_h, last_id: last_id, remaining: remaining, aborted: aborted
    }
  end

  def log_line
    LOG_KEYS.map { |key| "#{key}=#{to_h[key].inspect}" }.join(' ')
  end

  # One line per old status and provider status, then the outcomes that did not lead to a status.
  def summary_lines
    lines = transitions.sort.flat_map do |from, targets|
      targets.sort.map { |to, count| "  #{from} -> #{to}: #{count}" }
    end
    lines + automation_lines + outcome_lines
  end

  private

  # Status changes are applied as a data correction: no automation rule, CRM re-evaluation or new touch is triggered.
  def automation_lines
    return [] unless changed.positive?

    verb = dry_run ? 'would have triggered' : 'held back (not triggered)'
    ["  automation rules that #{verb}: #{automation_matches} of #{changed} status changes " \
     "(event match only, conditions not evaluated; active rules by event: #{automation_rules.inspect})"]
  end

  def outcome_lines
    lines = []
    lines << "  not found at MedElement (kept, not deleted): #{not_found} appointment ids #{not_found_appointment_ids.inspect}" if not_found.positive?
    lines << out_of_scope_line if out_of_scope.positive?
    lines << "  skipped: #{skipped_reasons.to_h.inspect}" if skipped.positive?
    lines << "  provider errors: #{error_codes.to_h.inspect}" if errors.positive?
    lines
  end

  # Receptions that the import refuses, by reason: the specialist is not mapped, the cabinet is unknown (the detail has none
  # and it cannot be taken from the appointment or from a single-cabinet specialist), or the reported cabinet is not the specialist's.
  def out_of_scope_line
    reasons = out_of_scope_reasons.sort_by { |reason, _count| reason.to_s }.map { |reason, count| "#{reason.to_s.tr('_', ' ')}: #{count}" }
    "  out of scope (refused by the import): #{out_of_scope} (#{reasons.join(', ')})"
  end
end
