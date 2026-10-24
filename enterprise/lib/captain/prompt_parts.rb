# frozen_string_literal: true

# The system prompt of an agent in two parts, in the order the provider reads them.
#
# stable: what is the same for every request of the agent, step after step and conversation after conversation: the platform rules,
#   the shared rules, the clinic instructions, the way of working with colleagues. The provider caches a request prefix byte for byte,
#   so this part comes first and holds nothing that changes from one request to the next.
# volatile: what changes per request: the clock ("# Now"), the patient language, the patient's data ("# Patient"), the data blocks of
#   the coordination (open parts, the accepted plan) and the notes of a retry. It comes last: a change in it costs only the tokens after it.
#
# #to_s is the whole prompt, the two parts joined by a blank line, as a single string would have been written.
Captain::PromptParts = Data.define(:stable, :volatile) do
  def self.stable_only(text)
    new(stable: text.to_s, volatile: '')
  end

  # Several parts in one: the stable texts together and the volatile texts together, blanks left out.
  def self.merge(parts)
    new(stable: join(parts.map(&:stable)), volatile: join(parts.map(&:volatile)))
  end

  def self.join(texts)
    texts.compact_blank.join("\n\n")
  end

  def to_s
    self.class.join([stable, volatile])
  end
end
