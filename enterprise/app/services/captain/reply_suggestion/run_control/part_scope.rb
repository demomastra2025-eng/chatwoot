# frozen_string_literal: true

# The control of a reply suggestion run as the parts of a council see it (RunControl#for_parts): everything of the run - its cancel,
# its deadline and the approval cards it prepared - and the earlier deadline of the parts.
class Captain::ReplySuggestion::RunControl::PartScope
  def initialize(run, deadline)
    @run = run
    @deadline = deadline
  end

  delegate :request_id, :action_ids, :register_action, :shorten!, :for_parts, to: :@run

  def checkpoint!(stage)
    @run.checkpoint!(stage)
    raise Captain::ReplySuggestion::RunControl::PartTimeUp, stage if monotonic_now >= @deadline
  end

  def seconds_left
    (@deadline - monotonic_now).clamp(0, @run.seconds_left)
  end

  private

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
