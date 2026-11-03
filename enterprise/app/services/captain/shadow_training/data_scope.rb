# frozen_string_literal: true

module Captain::ShadowTraining::DataScope
  def self.with(run, &)
    scope_id = Llm::IinTokenVault.conversation_scope_id(run.conversation)
    Llm::EgressGuard.with(validation: -> { Captain::ShadowTraining::Eligibility.ensure_run!(run) }) do
      Llm::IinTokenVault.with_scope(account_id: run.account_id, scope_id: scope_id) do
        Llm::PiiSessionPseudonymizer.with_scope(account_id: run.account_id, scope_id: scope_id, conversation: run.conversation, &)
      end
    end
  end
end
