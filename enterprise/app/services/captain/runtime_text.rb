# frozen_string_literal: true

# Writes the $ field references of a workspace text that a customer reads (a handoff or closing notice) as their plain values. The text
# belongs to the workspace, not to an agent, so the fields it may use are those of a patient-facing agent with the platform's default
# access (every selectable patient field), whoever sends the text.
module Captain::RuntimeText
  def self.render(text, account:, conversation: nil)
    patient_agent(account).render_runtime_text(text, conversation: conversation)
  end

  # Not stored: only the default access of an agent that talks to patients.
  def self.patient_agent(account)
    Captain::Assistant.new(account: account, usage_mode: 'external_agent', name: 'AI', description: '')
  end
  private_class_method :patient_agent
end
