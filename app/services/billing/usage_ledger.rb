# frozen_string_literal: true

# Source-only unit accounting. No producer, cron, invoice or client endpoint calls this service.
class Billing::UsageLedger
  class Refused < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code.to_s)
    end
  end

  def self.preview(**inputs)
    new(**inputs).preview
  end

  def self.reconcile!(**inputs)
    new(**inputs).reconcile!
  end

  def initialize(**inputs)
    @inputs = inputs
  end

  def preview
    input = Input.new(**@inputs)
    input.load!
    plan = Projection.new(input).build
    response(plan[:noop] ? :no_op : :ready, input.target, plan[:deltas])
  rescue Refused => e
    refusal(e)
  end

  def reconcile!
    input = Input.new(**@inputs)
    input.with_locks do
      plan = Projection.new(input).build
      next response(:no_op, input.target, {}) if plan[:noop]

      write!(input, plan)
    end
  rescue Refused => e
    refusal(e)
  end

  private

  def write!(input, plan)
    target = input.target || Billing::UsageProjection.new(account_id: input.account_id, kind: input.kind, subject_id: input.subject_id)
    version = (input.target&.version || 0) + 1
    target.update!(plan.slice(:sources, :allocations, :window_sources, :fingerprint).merge(version: version))
    plan[:deltas].sort.each { |period_id, delta| apply_period!(input.periods.fetch(period_id), delta, target, version) }
    input.merge_projections.each { |source| source.update!(retired_into: target, retired_at: Time.current, version: source.version + 1) }
    response(:applied, target, plan[:deltas])
  end

  def response(status, target, deltas)
    { status: status, code: nil, projection_id: target&.id, version: target&.version || 0, deltas: deltas }
  end

  def apply_period!(period, delta, target, version)
    dialogs = period.dialogs_count + delta.fetch('dialogs')
    seconds = period.call_seconds + delta.fetch('seconds')
    raise Refused, :negative_balance if dialogs.negative? || seconds.negative?

    period.update!(dialogs_count: dialogs, call_seconds: seconds, revision: period.revision + 1)
    Billing::UsageRevision.create!(usage_period: period, usage_projection: target, revision: period.revision,
                                   projection_version: version, dialogs_delta: delta['dialogs'], seconds_delta: delta['seconds'])
  end

  def refusal(error)
    status = error.code == :stale_projection ? :conflict : :needs_review
    { status: status, code: error.code, projection_id: nil, version: nil, deltas: {} }
  end
end
