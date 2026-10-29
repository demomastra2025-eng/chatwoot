# frozen_string_literal: true

# The state of the calling thread that a read-only lane needs on its own thread. A new thread starts empty: Current, the locale,
# the time zone and the event-bus context are all thread-local, and the query cache that the executor switches on would hide
# the writes of other processes from the fence checks (RunFenceService) and from the durable session.
#
# Only READ-ONLY lanes run on threads (see Council::Lanes); every mutating tool runs on the thread of the job, so none of
# this is needed for a write. Agents and tools are built on the calling thread, never here.
class Captain::Runtime::Council::ThreadScope
  # executed_by is set per part. Everything else is what the run was started with, among it the delivery policy of a
  # Playground run: a part must never deliver anything outside it.
  CURRENT_ATTRIBUTES = %i[user account account_user request_id contact suppress_runtime_events playground_run_policy].freeze

  # Captured on the calling thread, before any thread starts. The control of a reply suggestion run (its cancel, its deadline and
  # the approval cards it prepared) is the same object on every thread of the run.
  def self.capture
    new(
      current: CURRENT_ATTRIBUTES.index_with { |name| copy(Current.public_send(name)) },
      locale: I18n.locale, time_zone: Time.zone, event_context: Llm::EventBus.snapshot_context,
      run_control: Captain::ReplySuggestion::RunControl.current,
      iin_vault_scope: Llm::IinTokenVault.current_scope&.slice(:account_id, :scope_id)
    )
  end

  def self.copy(value)
    value.respond_to?(:deep_dup) && !value.is_a?(ActiveRecord::Base) ? value.deep_dup : value
  end

  def initialize(current:, locale:, time_zone:, event_context:, run_control: nil, iin_vault_scope: nil) # rubocop:disable Metrics/ParameterLists
    @current = current
    @locale = locale
    @time_zone = time_zone
    @event_context = event_context
    @run_control = run_control
    @iin_vault_scope = iin_vault_scope
  end

  # Runs the block on the current thread, which must be a thread of its own: Current is reset when the block ends. The executor
  # gives the thread's database connection back to the pool when the block ends (while no transaction is open on it).
  def run(executed_by: nil, &)
    Rails.application.executor.wrap do
      restore(executed_by)
      with_iin_vault do
        Captain::ReplySuggestion::RunControl.adopt(@run_control) do
          ActiveRecord::Base.uncached { Llm::EventBus.with_context(@event_context, &) }
        end
      end
    end
  ensure
    Current.reset
  end

  private

  def with_iin_vault(&)
    return yield if @iin_vault_scope.blank?

    Llm::IinTokenVault.with_scope(**@iin_vault_scope, &)
  end

  def restore(executed_by)
    @current.each { |name, value| Current.public_send("#{name}=", value) }
    Current.executed_by = executed_by
    I18n.locale = @locale
    Time.zone = @time_zone
  end
end
