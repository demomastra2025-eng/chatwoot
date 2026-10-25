# frozen_string_literal: true

# The run reached its hard cut (see HardCut). Not a StandardError: no rescue inside the run swallows it.
class Captain::ReplySuggestion::HardCut::Expired < Exception # rubocop:disable Lint/InheritException
end
