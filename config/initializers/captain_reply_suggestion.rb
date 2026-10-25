# frozen_string_literal: true

# The RubyLLM calls of a reply suggestion run end with the run (see Captain::ReplySuggestion::RunControl::RequestTimeout).
Rails.application.reloader.to_prepare do
  name = 'Captain::ReplySuggestion::RunControl::RequestTimeout'
  RubyLLM::Connection.prepend(name.constantize) if RubyLLM::Connection.ancestors.none? { |mod| mod.name == name }
end
