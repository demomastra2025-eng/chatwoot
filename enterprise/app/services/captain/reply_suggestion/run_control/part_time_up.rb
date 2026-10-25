# frozen_string_literal: true

# The deadline of the parts of a council passed (not the deadline of the run, see RunControl#for_parts). A StandardError on purpose:
# the part that raised it ends as a technical failure of its own, and the run goes on with the other parts and the editor.
class Captain::ReplySuggestion::RunControl::PartTimeUp < StandardError
  attr_reader :stage

  def initialize(stage)
    @stage = stage.to_s
    super("Council part out of time at #{@stage}")
  end
end
