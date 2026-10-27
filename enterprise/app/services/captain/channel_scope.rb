# frozen_string_literal: true

# The channel an AI run belongs to. The identity of a run is the channel, never an agent: every enabled external agent of the
# workspace is a peer, and the router (Captain::Runtime::DecisionRouter) picks the one that answers each turn.
#   text       a text inbox, and the conversations in it. Its members are all enabled external agents of the workspace.
#   voice      a phone number. A call has no router, so the number names its voice agent (the only member).
#   workspace  the Playground without a channel: the whole AI of the workspace is tried out, like a text inbox.
# The scope says who may take part (#members, see Captain::AgentGraph for who the router chooses among) and whether the AI may answer
# in the channel by itself (#runtime_enabled?). It never names a main or default agent.
class Captain::ChannelScope
  attr_reader :account, :inbox, :kind, :voice_agent

  class << self
    def for_conversation(conversation)
      for_inbox(conversation.inbox, account: conversation.account)
    end

    def for_inbox(inbox, account: inbox.account)
      return new(account: account, inbox: inbox, kind: :text) unless inbox.channel_type == CaptainInbox::VOICE_CHANNEL_TYPE

      new(account: account, inbox: inbox, kind: :voice, voice_agent: voice_agent_of(inbox))
    end

    # The Playground tries out the whole AI of the workspace; a voice channel gives the agent of that number alone.
    def for_playground(account, inbox = nil)
      return new(account: account, kind: :workspace) if inbox.nil?

      for_inbox(inbox, account: account)
    end

    private

    def voice_agent_of(inbox)
      CaptainInbox.find_by(inbox_id: inbox.id)&.captain_assistant
    end
  end

  def initialize(account:, kind:, inbox: nil, voice_agent: nil)
    @account = account
    @inbox = inbox
    @kind = kind
    @voice_agent = voice_agent
  end

  def text? = kind == :text

  def voice? = kind == :voice

  def workspace? = kind == :workspace

  # For logs only.
  def key
    inbox ? "inbox:#{inbox.id}" : "playground:#{account.id}"
  end

  # The enabled external agents that may act in this channel, in the order of their ids. A voice number has its agent alone, and
  # only while that agent is enabled.
  def members
    @members ||= if voice?
                   [voice_agent].compact.select { |agent| agent.account_id == account.id && agent.entry_eligible? }
                 else
                   account.captain_assistants.entry_eligible.order(:id).to_a
                 end
  end

  def agents_available?
    return members.any? if voice? || @members

    account.captain_assistants.entry_eligible.exists?
  end

  # Whether the AI may answer in this channel by itself: the number's agent is enabled (voice), or the channel is switched on, the
  # workspace AI is on and at least one external agent is enabled (text). Turning off one agent never closes a channel that has another.
  def runtime_enabled?
    return agents_available? && account.captain_ai_enabled? if workspace?

    CaptainInbox.enabled_for_runtime.exists?(inbox_id: inbox.id)
  end
end
