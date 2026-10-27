# frozen_string_literal: true

# The post-deploy smoke check of the router (rake captain:router_smoke). The router is the only way an agent is chosen and has no
# fallback: when every decision model fails, every turn of a clinic with two or more agents fails (and every reply suggestion
# ends router_unavailable). This check makes ONE real call per model of the routing chain (each model alone, with the same
# questions the router asks) on a synthetic turn of two synthetic agents.
#
# A row names the model, its role, the latency and ok or the error class. Never a key, a prompt, a provider body or a text: the
# turn is synthetic and is not printed either. ok means the model answered and its answers resolve into one decision.
class Captain::Runtime::DecisionRouter::Smoke
  Row = Struct.new(:role, :model, :ok, :latency_ms, :decision, :error, keyword_init: true) do
    def to_s
      outcome = ok ? "ok decision=#{decision}" : "fail error=#{error}"
      "#{role.ljust(12)} #{model.to_s.ljust(36)} #{outcome} latency_ms=#{latency_ms}"
    end
  end

  AGENTS = [
    Captain::Runtime::RoutingSnapshot::Agent.new(id: 1, label: 'Doctors', card: 'Appointments with doctors: therapist, cardiologist.'),
    Captain::Runtime::RoutingSnapshot::Agent.new(id: 2, label: 'Laboratory', card: 'Blood and urine tests, their prices and preparation.')
  ].freeze
  MESSAGE = 'Хочу записаться к терапевту на завтра утром'
  OBSERVABILITY = { operation: 'captain.router_smoke', source: 'smoke' }.freeze

  # account: the account the calls are made for (its key and its budget check); models: the chain to check (the platform chain of
  # the router by default).
  def initialize(account:, models: nil)
    @account = account
    @models = Array(models).presence || Llm::DecisionChain.models(Captain::Runtime::DecisionRouter::FEATURE)
    @snapshot = Captain::Runtime::RoutingSnapshot.new(agents: AGENTS, latest_message: MESSAGE, human_available: true, source: 'smoke')
    @questions = Captain::Runtime::DecisionRouter::Questions.build(@snapshot, instructions: Captain::Runtime::DecisionRouter::INSTRUCTIONS)
  end

  # Every row, in chain order.
  def call
    @models.each_with_index.map { |model, index| chain_row(model, index + 1) }
  end

  def self.ok?(rows)
    rows.all?(&:ok)
  end

  # The accounts that route: a text channel of theirs gives the router two or more candidates (two or more enabled agents with a
  # competence card). Each is checked with its own key and budget, so a green check means every clinic can route. In the order of
  # their ids.
  def self.routed_accounts
    ids = CaptainInbox.includes(inbox: :account).filter_map do |link|
      next if link.inbox.nil? || link.inbox.channel_type == CaptainInbox::VOICE_CHANNEL_TYPE

      link.inbox.account_id unless Captain::AgentGraph.new(Captain::ChannelScope.for_inbox(link.inbox)).solo?
    rescue StandardError
      nil
    end
    Account.where(id: ids.uniq).order(:id).to_a
  end

  private

  def chain_row(model, position)
    measured("chain##{position}", model) do
      result = Llm::DecisionChain.decide(
        feature: Captain::Runtime::DecisionRouter::FEATURE, account: @account, models: [model],
        question: { state: @snapshot.to_state, questions: @questions.to_h },
        total_timeout: Captain::Runtime::DecisionRouter::Settings.chain_budget_seconds,
        observability: OBSERVABILITY.merge(decision_criteria_count: @questions.size)
      )
      @questions.resolve(result.answers)
    end
  end

  # The block returns the resolved outcome (nil when the answers resolve into none).
  def measured(role, model)
    started = monotonic_now
    outcome = yield
    Row.new(role: role, model: model, ok: outcome.present?, decision: outcome&.key, error: ('unresolved' unless outcome),
            latency_ms: elapsed_ms(started))
  rescue StandardError => e
    Row.new(role: role, model: model, ok: false, error: error_name(e), latency_ms: elapsed_ms(started))
  end

  # The class of the error and, for the router's own errors, their codes: names only.
  def error_name(error)
    detail = error.respond_to?(:reason) ? error.reason : nil
    attempts = error.respond_to?(:attempts) ? error.attempts.pluck(:error_class).join(',') : nil
    [error.class.name, detail, attempts].compact_blank.join(':')
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started)
    ((monotonic_now - started) * 1000).round
  end
end
